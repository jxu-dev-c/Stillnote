import AVFoundation
import Foundation

public enum AudioMixError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Mixes the time-aligned capture sources into one mono file without loading a
/// meeting into memory: one second of audio is read, summed, and written at a time.
public enum AudioMixer {
    private static let blockFrames: AVAudioFrameCount = AVAudioFrameCount(captureRate)

    @discardableResult
    public static func mix(sessionDirectory: URL, to destination: URL) throws -> Double {
        var inputs: [AVAudioFile] = []
        for name in ["microphone.wav", "system.wav"] {
            let url = sessionDirectory.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            guard size > 44 else { continue }
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forReading: url)
            } catch {
                throw AudioMixError.message(
                    "A captured audio file is damaged. The original files remain on disk."
                )
            }
            let format = file.fileFormat
            guard format.channelCount == 1, Int(format.sampleRate) == captureRate,
                  format.streamDescription.pointee.mBitsPerChannel == 16
            else {
                throw AudioMixError.message(
                    "The captured audio format is invalid. The original files remain on disk."
                )
            }
            inputs.append(file)
        }
        guard !inputs.isEmpty else {
            throw AudioMixError.message(
                "No audio was captured. Check microphone permissions and start a new recording."
            )
        }
        let frames = inputs.map(\.length).max() ?? 0
        guard frames <= Int64(captureRate) * Int64(Validation.maxRecordingSeconds + 2) else {
            throw AudioMixError.message("The captured audio exceeds the recording limit.")
        }

        let working = inputs[0].processingFormat
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Double(captureRate),
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            commonFormat: working.commonFormat,
            interleaved: working.isInterleaved
        )
        let gain = Float(1) / Float(inputs.count)
        var position: Int64 = 0
        guard let mixed = AVAudioPCMBuffer(pcmFormat: working, frameCapacity: blockFrames),
              let scratch = AVAudioPCMBuffer(pcmFormat: working, frameCapacity: blockFrames)
        else {
            throw AudioMixError.message("Could not allocate the audio mixing buffer.")
        }
        while position < frames {
            let length = AVAudioFrameCount(min(Int64(blockFrames), frames - position))
            mixed.frameLength = length
            guard let target = mixed.floatChannelData?[0] else { break }
            target.update(repeating: 0, count: Int(length))
            for file in inputs where file.framePosition < file.length {
                scratch.frameLength = 0
                try file.read(into: scratch, frameCount: length)
                guard let samples = scratch.floatChannelData?[0] else { continue }
                for index in 0..<Int(scratch.frameLength) {
                    // Equal gain leaves headroom even with both voices at full scale.
                    target[index] += samples[index] * gain
                }
            }
            for index in 0..<Int(length) { target[index] = max(-1, min(1, target[index])) }
            try output.write(from: mixed)
            position += Int64(length)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return Double(frames) / Double(captureRate)
    }
}
