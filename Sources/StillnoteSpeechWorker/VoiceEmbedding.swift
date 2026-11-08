import CoreML
import Foundation
import StillnoteCore

/// Embeds speaker windows with WeSpeaker ResNet34 (pyannote community-1, Core ML).
///
/// Two compiled models run back to back: `FBank` turns ten seconds of audio into 80-bin
/// filterbank features, and `Embedding` pools those features under a per-frame mask into a
/// unit-length 256-dimensional voice embedding. Both accept batches of 1–32 windows.
enum VoiceEmbedding {
    private static let batchSize = 16

    /// `arguments` is everything after the `embed` subcommand:
    /// `<pcm-path> <model-directory> <windows-json-path>`
    static func run(arguments: [String]) throws {
        guard arguments.count == 3 else {
            throw SpeechError.message("Voice recognition was started with unexpected arguments.")
        }
        let pcmURL = URL(fileURLWithPath: arguments[0])
        let modelURL = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let windowsURL = URL(fileURLWithPath: arguments[2])
        let rate = AudioDecoder.sampleRate

        let size = (try FileManager.default.attributesOfItem(atPath: pcmURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size % 4 == 0, size <= Int(Validation.maxRecordingSeconds) * rate * 4 else {
            throw SpeechError.message("Invalid audio or recording exceeds the 90-minute limit.")
        }
        let totalSamples = size / 4
        let windows = try JSONDecoder().decode([VoiceWindow].self, from: Data(contentsOf: windowsURL))
        guard windows.count <= 20_000,
              windows.allSatisfy({ $0.start.isFinite && $0.start >= 0 && $0.spans.allSatisfy { $0.count == 2 } })
        else {
            throw SpeechError.message("Voice recognition was given invalid windows.")
        }

        Worker.event(["type": "progress", "progress": 0, "detail": "Loading the voice model"])
        let frontend = MLModelConfiguration()
        frontend.computeUnits = .cpuOnly
        let backend = MLModelConfiguration()
        backend.computeUnits = .all
        let fbank = try MLModel(contentsOf: modelURL.appendingPathComponent("FBank.mlmodelc"), configuration: frontend)
        let embedder = try MLModel(
            contentsOf: modelURL.appendingPathComponent("Embedding.mlmodelc"), configuration: backend
        )

        let handle = try FileHandle(forReadingFrom: pcmURL)
        defer { try? handle.close() }
        let length = VoiceRecognition.windowSamples
        let frames = VoiceRecognition.maskFrames
        var vectors: [[Float]] = []
        vectors.reserveCapacity(windows.count)
        var lastReport = Date.distantPast

        var index = 0
        while index < windows.count {
            let batch = Array(windows[index ..< min(windows.count, index + batchSize)])
            let audio = try MLMultiArray(shape: [NSNumber(value: batch.count), 1, NSNumber(value: length)], dataType: .float32)
            let weights = try MLMultiArray(shape: [NSNumber(value: batch.count), NSNumber(value: frames)], dataType: .float32)
            let audioPointer = audio.dataPointer.bindMemory(to: Float.self, capacity: batch.count * length)
            let weightPointer = weights.dataPointer.bindMemory(to: Float.self, capacity: batch.count * frames)
            for (row, window) in batch.enumerated() {
                let first = min(totalSamples, max(0, Int((window.start * Double(rate)).rounded())))
                let count = min(length, totalSamples - first)
                var samples = [Float](repeating: 0, count: length)
                if count > 0 {
                    try handle.seek(toOffset: UInt64(first * 4))
                    guard let data = try handle.read(upToCount: count * 4), data.count == count * 4 else {
                        throw SpeechError.message("The decoded audio ended unexpectedly.")
                    }
                    samples.withUnsafeMutableBytes { buffer in
                        _ = data.copyBytes(to: UnsafeMutableRawBufferPointer(rebasing: buffer[0 ..< count * 4]))
                    }
                }
                guard samples.allSatisfy(\.isFinite) else {
                    throw SpeechError.message("This recording contains no valid audio.")
                }
                samples.withUnsafeBufferPointer { source in
                    (audioPointer + row * length).update(from: source.baseAddress!, count: length)
                }
                let mask = window.frameWeights()
                mask.withUnsafeBufferPointer { source in
                    (weightPointer + row * frames).update(from: source.baseAddress!, count: frames)
                }
            }

            let features = try fbank.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": audio]))
            guard let fbankFeatures = features.featureValue(for: "fbank_features")?.multiArrayValue else {
                throw SpeechError.message("The voice model returned no features.")
            }
            let output = try embedder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "fbank_features": fbankFeatures, "weights": weights,
            ]))
            guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue,
                  embedding.shape.count == 2, embedding.shape[0].intValue == batch.count,
                  embedding.shape[1].intValue == VoiceRecognition.dimension
            else {
                throw SpeechError.message("The voice model returned an unexpected embedding.")
            }
            for row in 0 ..< batch.count {
                // Keyed access honours the output's strides, whatever layout Core ML chose.
                vectors.append((0 ..< VoiceRecognition.dimension).map { column in
                    embedding[[NSNumber(value: row), NSNumber(value: column)]].floatValue
                })
            }

            index += batch.count
            if Date().timeIntervalSince(lastReport) >= 0.5 || index == windows.count {
                lastReport = Date()
                Worker.event([
                    "type": "progress", "progress": 100 * Double(index) / Double(windows.count),
                    "detail": "Recognizing voices · \(index)/\(windows.count)",
                ])
            }
        }
        Worker.event(["type": "embeddings", "vectors": vectors.map { $0.map { Double($0) } }])
    }
}
