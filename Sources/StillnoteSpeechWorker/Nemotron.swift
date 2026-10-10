import AudioCommon
import CoreML
import Foundation
import NemotronStreamingASR
import SpeechVAD
import StillnoteCore

/// Nemotron 3.5 ASR and Nemotron 3 Diarization over CoreML.
///
/// Both runtimes document themselves as unsafe for concurrent inference, so everything here
/// runs on one thread and the two models are driven in lockstep over the same audio: the
/// recognizer produces words, the diarizer produces a speaker timeline, and Core fuses them.
/// Audio is read in windows so a 90-minute meeting is never resident in memory.
enum Nemotron {
    /// 16 kHz mono float32, matching `AudioDecoder`'s output.
    private static let sampleRate = 16_000
    /// One second of audio per push. The ASR session re-chunks internally to the bundle's
    /// 320 ms geometry; this only bounds how much PCM is resident.
    private static let windowSamples = 16_000

    /// One live block: 320 ms at 16 kHz, matching the ASR bundle's fixed chunk geometry.
    private static let liveBlockSamples = 5_120

    static func run(arguments: [String]) async throws {
        guard let json = arguments.first, arguments.count == 1 else {
            throw SpeechError.message("The speech worker was started with unexpected arguments.")
        }
        let request = try NemotronWorkerRequest(json: json)
        if request.geometry == .live {
            try await runLive(request: request)
            return
        }
        guard let pcmPath = request.pcmPath else {
            throw SpeechError.message("The speech worker was started without audio.")
        }
        let pcmURL = URL(fileURLWithPath: pcmPath)

        let size = (try FileManager.default.attributesOfItem(atPath: pcmURL.path)[.size]
            as? NSNumber)?.intValue ?? 0
        guard size > 0, size % 4 == 0,
              size <= Int(Validation.maxRecordingSeconds) * sampleRate * 4
        else {
            throw SpeechError.message("Invalid audio or recording exceeds the 90-minute limit.")
        }
        let totalSamples = size / 4
        let duration = Double(totalSamples) / Double(sampleRate)

        Worker.event(["type": "progress", "progress": 8,
                      "detail": "Loading the speech engine on the Neural Engine"])
        let engine = try await Engine.load(request: request)
        Worker.event(["type": "progress", "progress": 14,
                      "detail": "Transcribing on the Neural Engine · 0 / \(Int(duration)) seconds"])

        let transcript = try engine.transcribe(
            pcmURL: pcmURL, totalSamples: totalSamples, duration: duration
        )
        let payload = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(transcript)
        )
        Worker.event(["type": "transcript", "transcript": payload])
    }

    /// Transcribes a recording while it is still being made.
    ///
    /// Audio arrives on stdin as raw 16 kHz mono float32 — the app's `LiveAudioTap` mixes the
    /// microphone and system audio and resamples before writing, so this side stays a plain
    /// stream. EOF means the recording stopped.
    ///
    /// Partials send only the words added since the last one, which keeps a 90-minute meeting
    /// from re-sending its whole transcript twice a second, and resend the speaker timeline,
    /// which stays small. That is safe because both models only append: RNN-T greedy decoding
    /// is monotonic, and the diarizer's confirmed segments only grow.
    ///
    /// With one exception. Words are grouped from tokens on SentencePiece's word-start marker,
    /// so the *last* word is still being assembled until the next word begins — "faster"
    /// passes through as "fa". A partial therefore holds the trailing word back and the final
    /// emission releases it.
    static func runLive(request: NemotronWorkerRequest) async throws {
        let engine = try await Engine.load(request: request)
        let boosting = request.hotWords.isEmpty
            ? nil
            : WordBoostingConfig(phrases: request.hotWords)
        let language = request.language == "auto" ? nil : request.language
        let session = try engine.asr.createSession(language: language, wordBoosting: boosting)
        let diarization = try engine.diarizer.makeStreamingSession(
            coreEncoderFrames: request.geometry.coreEncoderFrames,
            rightContextEncoderFrames: request.geometry.rightContextEncoderFrames
        )
        Worker.event(["type": "ready", "engine": "Nemotron · CoreML"])

        let input = FileHandle.standardInput
        var words: [TimedWord] = []
        var activity: [DiarizedSegment] = []
        var sent = 0
        let gate = ProgressGate()

        func emit(final: Bool) {
            let complete = final ? words.count : max(0, words.count - 1)
            let added = complete > sent ? Array(words[sent..<complete]) : []
            sent = complete
            Worker.event([
                // `transcript` stays the offline verb's self-contained payload. A partial is
                // incremental, so it says whether it is the last one rather than pretending
                // to be a whole transcript.
                "type": "partial",
                "final": final,
                "language": request.language,
                "words": added.map {
                    ["text": $0.text, "start": $0.startTime, "end": $0.endTime]
                },
                "activity": activity.map {
                    ["speaker": $0.speakerId, "start": Double($0.startTime),
                     "end": Double($0.endTime)]
                },
            ])
        }

        // A short read is normal on a pipe, so blocks are assembled before pushing: the ASR
        // session re-chunks internally, but handing it ragged blocks would make the diarizer's
        // fixed geometry do more work than it needs to.
        var pending = Data()
        let blockBytes = liveBlockSamples * 4
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while pending.count >= blockBytes {
                let block = pending.prefix(blockBytes)
                pending.removeFirst(blockBytes)
                let samples = block.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                guard samples.allSatisfy({ $0.isFinite }) else { continue }
                // See `Engine.transcribe`: without a pool per block, a long recording
                // exhausts IOSurfaces.
                try autoreleasepool {
                    if let latest = try session.pushAudio(samples).last { words = latest.words }
                    activity = try diarization.push(audio: samples).segments
                }
                if gate.allow() { emit(final: false) }
            }
        }
        // Whatever is left is shorter than a block; the models pad their own input.
        if !pending.isEmpty, pending.count % 4 == 0 {
            let samples = pending.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            if samples.allSatisfy({ $0.isFinite }) {
                if let latest = try session.pushAudio(samples).last { words = latest.words }
                activity = try diarization.push(audio: samples).segments
            }
        }
        if let final = try session.finalize().last { words = final.words }
        activity = try diarization.finish().segments
        emit(final: true)
    }

    /// The loaded pair, plus the session geometry the request asked for.
    struct Engine {
        let asr: NemotronStreamingASRModel
        let diarizer: Nemotron3Diarizer
        let request: NemotronWorkerRequest
        /// What CoreML actually ran on: the Neural Engine, or the GPU fallback.
        let computeUnits: MLComputeUnits

        static func load(request: NemotronWorkerRequest) async throws -> Engine {
            let asrURL = URL(fileURLWithPath: request.asrModelPath)
            let diarizerURL = URL(fileURLWithPath: request.diarizerModelPath)
            // The encoder is palettized INT8 and compiles for the Neural Engine; the LSTM
            // decoder and the joint network are small and run on the CPU either way.
            // Compiling for the ANE has been reported to fail on some machines, so a failure
            // falls back to the GPU rather than failing the transcription.
            for units in [MLComputeUnits.all, .cpuAndGPU] {
                do {
                    let asr = try await NemotronStreamingASRModel.fromLocal(
                        bundleDir: asrURL, computeUnits: units
                    )
                    let diarizer = try Nemotron3Diarizer.fromCoreMLDirectory(
                        diarizerURL, computeUnits: units
                    )
                    if units != .all {
                        Worker.event([
                            "type": "progress", "progress": 10,
                            "detail": "Using the GPU: this Mac could not compile for the Neural Engine",
                        ])
                    }
                    return Engine(asr: asr, diarizer: diarizer, request: request,
                                  computeUnits: units)
                } catch {
                    if units == .cpuAndGPU { throw error }
                }
            }
            throw SpeechError.message("The speech engine could not be loaded.")
        }

        func transcribe(
            pcmURL: URL, totalSamples: Int, duration: Double
        ) throws -> NemotronWorkerTranscript {
            let boosting = request.hotWords.isEmpty
                ? nil
                : WordBoostingConfig(phrases: request.hotWords)
            let language = request.language == "auto" ? nil : request.language
            let session = try asr.createSession(language: language, wordBoosting: boosting)
            let diarization = try diarizer.makeStreamingSession(
                coreEncoderFrames: request.geometry.coreEncoderFrames,
                rightContextEncoderFrames: request.geometry.rightContextEncoderFrames
            )

            let handle = try FileHandle(forReadingFrom: pcmURL)
            defer { try? handle.close() }

            var words: [TimedWord] = []
            var processed = 0
            let gate = ProgressGate()
            while let block = try handle.read(upToCount: Nemotron.windowSamples * 4),
                  !block.isEmpty {
                let samples = block.withUnsafeBytes { raw in
                    Array(raw.bindMemory(to: Float.self))
                }
                guard samples.allSatisfy({ $0.isFinite }) else {
                    throw SpeechError.message("The local audio file could not be read.")
                }
                // `words` is cumulative for the whole session, so the newest partial
                // supersedes the previous one rather than appending to it.
                //
                // CoreML returns IOSurface-backed outputs autoreleased, and the vendored ASR
                // session does not drain a pool around its predictions. This loop never
                // returns to a run loop, so without a pool per window the surfaces pile up
                // until allocation fails — measured at about 590 s into a 16-minute meeting.
                try autoreleasepool {
                    if let latest = try session.pushAudio(samples).last { words = latest.words }
                    _ = try diarization.push(audio: samples)
                }
                processed += samples.count
                let seconds = Double(processed) / Double(Nemotron.sampleRate)
                if gate.allow() {
                    Worker.event([
                        "type": "progress",
                        "progress": 14 + 80 * seconds / max(duration, 1),
                        "detail": "Transcribing on the Neural Engine · "
                            + "\(Int(seconds)) / \(Int(duration)) seconds",
                    ])
                }
            }
            if let final = try session.finalize().last { words = final.words }
            let result = try diarization.finish()

            Worker.event(["type": "progress", "progress": 96, "detail": "Labeling speakers"])
            return NemotronWorkerTranscript(
                language: request.language,
                words: words.map {
                    TranscribedWord(text: $0.text, start: $0.startTime, end: $0.endTime)
                },
                activity: result.segments.map {
                    SpeakerActivity(
                        speaker: $0.speakerId, start: Double($0.startTime),
                        end: Double($0.endTime)
                    )
                }
            )
        }
    }
}

/// Throttles progress to twice a second.
private final class ProgressGate {
    private var last = Date.distantPast
    func allow() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.5 else { return false }
        last = now
        return true
    }
}
