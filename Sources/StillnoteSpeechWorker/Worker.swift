import Foundation
import StillnoteCore
import MLX
import MossTranscribeDiarize

@main
struct Worker {
    private static let timestampPattern = try! NSRegularExpression(pattern: #"\[([0-9]+(?:\.[0-9]+)?)\]"#)
    static func event(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        FileHandle.standardOutput.write(Data("STILLNOTE_EVENT ".utf8) + data + Data([10]))
    }

    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--self-test"] {
                let result = (MLXArray([Float(1), 2, 3]) * 2).sum().item(Float.self)
                guard result == 12 else { exit(1) }
                event(["type": "ready", "engine": "Native Swift MLX"])
                return
            }
            let request = try SpeechWorkerRequest(arguments: args)
            guard let recommended = GPU.maxRecommendedWorkingSetBytes() else {
                throw NSError(domain: "Stillnote", code: 3, userInfo: [NSLocalizedDescriptionKey: "The Apple GPU is unavailable."])
            }
            Memory.memoryLimit = min(6 * 1024 * 1024 * 1024, Int(Double(recommended) * 0.7))
            Memory.cacheLimit = 256 * 1024 * 1024
            event(["type": "progress", "progress": 8, "detail": "Loading MOSS on Apple GPU"])
            let size = (try FileManager.default.attributesOfItem(atPath: request.pcmURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0, size % 4 == 0, size <= Int(Validation.maxRecordingSeconds) * 16000 * 4 else {
                throw SpeechError.message("Invalid audio or recording exceeds the 90-minute limit.")
            }
            let data = try Data(contentsOf: request.pcmURL, options: .mappedIfSafe)
            guard data.count == size else {
                throw NSError(domain: "Stillnote", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid PCM audio."])
            }
            let samples = data.withUnsafeBytes { bytes in
                stride(from: 0, to: bytes.count, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: Float.self) }
            }
            let duration = Double(samples.count) / 16000
            guard duration <= Validation.maxRecordingSeconds, samples.allSatisfy({ $0.isFinite }) else {
                throw SpeechError.message("Invalid audio or recording exceeds the 90-minute limit.")
            }
            let model = try await ModelLoader.load(directory: request.modelURL)
            let budget = SpeechWorkerRequest.tokenBudget(duration: duration)
            let result = try model.generate(audio: MLXArray(samples), parameters: .init(maxTokens: budget, prefillStepSize: 512, prompt: request.prompt)) { update in
                switch update {
                case .encoding(let done, let total):
                    event(["type": "progress", "progress": 10 + 30 * Double(done) / Double(total), "detail": "Encoding audio on Apple GPU · \(done)/\(total)"])
                case .prefill(let done, let total):
                    event(["type": "progress", "progress": 40 + 15 * Double(done) / Double(total), "detail": "Processing meeting context · \(done)/\(total) tokens"])
                case .decoded(let text):
                    let seconds = timestampPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> Double? in
                        guard let range = Range(match.range(at: 1), in: text) else { return nil }
                        return Double(text[range])
                    }.max() ?? 0
                    let elapsed = min(duration, seconds)
                    event(["type": "progress", "progress": 55 + 40 * elapsed / max(duration, 1), "detail": "Transcribing on Apple GPU · \(Int(elapsed)) / \(Int(duration)) seconds"])
                }
            }
            event(["type": "result", "text": result.text])
        } catch {
            event(["type": "error", "message": error.localizedDescription])
            exit(1)
        }
    }
}
