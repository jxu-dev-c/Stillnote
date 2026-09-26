import Foundation
import MLX
import MLXAudioVAD
import StillnoteCore

/// Locates speech in a decoded recording with Silero VAD.
///
/// This runs in the worker rather than the app because it is MLX work: keeping every Metal
/// dependency behind a process boundary is what lets the app itself stay free of MLX, and it
/// means a native crash here cannot take the app down.
enum VoiceActivity {
    /// Silero consumes exactly 512 samples per step at 16 kHz.
    private static let chunkSamples = 512
    /// Read about 30 seconds at a time, an exact multiple of the chunk size so that only the
    /// final window is ever zero-padded. Padding mid-stream would shift every later
    /// chunk off its true position in the timeline.
    private static let windowChunks = 960

    struct Options {
        var threshold: Float = 0.5
        var minSpeechDurationMs = 250
        var minSilenceDurationMs = 100
        var speechPadMs = 30

        init(arguments: [String]) throws {
            func number(_ index: Int) throws -> Double? {
                guard index < arguments.count else { return nil }
                guard let value = Double(arguments[index]) else {
                    throw SpeechError.message("The silence detector was given an invalid setting.")
                }
                return value
            }
            if let value = try number(0) {
                guard value > 0, value < 1 else {
                    throw SpeechError.message("The speech threshold must be between 0 and 1.")
                }
                threshold = Float(value)
            }
            if let value = try number(1) { minSpeechDurationMs = max(0, Int(value)) }
            if let value = try number(2) { minSilenceDurationMs = max(0, Int(value)) }
            if let value = try number(3) { speechPadMs = max(0, Int(value)) }
        }
    }

    /// `arguments` is everything after the `vad` subcommand:
    /// `<pcm-path> <model-directory> [<threshold> <min-speech-ms> <min-silence-ms> <pad-ms>]`
    static func run(arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw SpeechError.message("The silence detector was started with unexpected arguments.")
        }
        let pcmURL = URL(fileURLWithPath: arguments[0])
        let modelURL = URL(fileURLWithPath: arguments[1])
        let options = try Options(arguments: Array(arguments.dropFirst(2)))
        let rate = AudioDecoder.sampleRate

        let size = (try FileManager.default.attributesOfItem(atPath: pcmURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size % 4 == 0, size <= Int(Validation.maxRecordingSeconds) * rate * 4 else {
            throw SpeechError.message("Invalid audio or recording exceeds the 90-minute limit.")
        }
        let total = size / 4

        Worker.event(["type": "progress", "progress": 0, "detail": "Loading the silence detector"])
        let model = try SileroVAD.fromModelDirectory(modelURL)

        let handle = try FileHandle(forReadingFrom: pcmURL)
        defer { try? handle.close() }

        var probabilities: [Float] = []
        probabilities.reserveCapacity(total / chunkSamples + 1)
        var state: SileroVADStreamingState? = nil
        let windowSamples = chunkSamples * windowChunks
        var position = 0

        while position < total {
            let count = min(windowSamples, total - position)
            guard let data = try handle.read(upToCount: count * 4), data.count == count * 4 else {
                throw SpeechError.message("The decoded audio ended unexpectedly.")
            }
            var samples = [Float](repeating: 0, count: count)
            _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            guard samples.allSatisfy(\.isFinite) else {
                throw SpeechError.message("This recording contains no valid audio.")
            }
            // Only the final window is padded, so chunk positions stay true to the timeline.
            let padding = (chunkSamples - count % chunkSamples) % chunkSamples
            if padding > 0 { samples.append(contentsOf: [Float](repeating: 0, count: padding)) }

            let window = MLXArray(samples)
            var pending: [MLXArray] = []
            var offset = 0
            while offset < samples.count {
                let (probability, next) = try model.feed(
                    chunk: window[offset ..< offset + chunkSamples], state: state, sampleRate: rate
                )
                state = next
                pending.append(probability)
                offset += chunkSamples
                // Let the graph settle periodically instead of growing across the window.
                if pending.count % 16 == 0, let carried = next.lstmState {
                    asyncEval([probability, carried])
                }
            }
            let joined = concatenated(pending, axis: 1)
            eval(joined)
            if let carried = state?.lstmState { eval(carried) }
            probabilities.append(contentsOf: joined[0].asArray(Float.self))

            position += count
            Worker.event([
                "type": "progress", "progress": 100 * Double(position) / Double(total),
                "detail": "Detecting speech · \(position / rate) / \(total / rate) seconds",
            ])
        }

        let timestamps = SileroVAD.probsToTimestamps(
            MLXArray(probabilities), audioLen: total, sampleRate: rate,
            threshold: options.threshold, minSpeechDurationMs: options.minSpeechDurationMs,
            minSilenceDurationMs: options.minSilenceDurationMs, speechPadMs: options.speechPadMs
        )
        let ranges = timestamps.map { stamp in
            [Double(stamp.start) / Double(rate), Double(stamp.end) / Double(rate)]
        }
        Worker.event(["type": "ranges", "ranges": ranges])
    }
}
