import Foundation
import MLX
import StillnoteCore

@main
struct Worker {
    static func event(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        FileHandle.standardOutput.write(Data("STILLNOTE_EVENT ".utf8) + data + Data([10]))
    }

    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--self-test"] {
                // Silero VAD is the one remaining MLX model, so the metallib beside this
                // binary still has to load. `SpeechWorkerLocator.runtimeReady` checks for the
                // file; this proves the kernels actually run.
                let result = (MLXArray([Float(1), 2, 3]) * 2).sum().item(Float.self)
                guard result == 12 else { exit(1) }
                event(["type": "ready", "engine": "Native Swift · CoreML · MLX"])
                return
            }
            // A leading verb selects the engine: `vad` for silence detection on MLX,
            // `nemotron` for the CoreML transcription and diarization pair.
            switch args.first {
            case "vad":
                try VoiceActivity.run(arguments: Array(args.dropFirst()))
            case "nemotron":
                try await Nemotron.run(arguments: Array(args.dropFirst()))
            default:
                throw SpeechError.message(
                    "The speech worker was started with unexpected arguments."
                )
            }
        } catch {
            event(["type": "error", "message": error.localizedDescription])
            exit(1)
        }
    }
}
