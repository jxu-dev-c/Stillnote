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
            Memory.memoryLimit = min(Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.6), Int(Double(recommended) * 0.7))
            // Benchmark override may lower the budget, never raise it.
            if let raw = ProcessInfo.processInfo.environment["STILLNOTE_MEMORY_BUDGET_MB"],
               let megabytes = Int(raw), megabytes > 0, megabytes <= Memory.memoryLimit / (1024 * 1024) {
                Memory.memoryLimit = megabytes * 1024 * 1024
            }
            Memory.cacheLimit = 256 * 1024 * 1024
            event(["type": "progress", "progress": 8, "detail": "Loading MOSS on Apple GPU"])
            let size = (try FileManager.default.attributesOfItem(atPath: request.pcmURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0, size % 4 == 0, size <= Int(Validation.maxRecordingSeconds) * 16000 * 4 else {
                throw SpeechError.message("Invalid audio or recording exceeds the 90-minute limit.")
            }
            let duration = Double(size / 4) / 16000
            let loadStart = Date()
            let model = try await ModelLoader.load(directory: request.modelURL)
            let loadSeconds = Date().timeIntervalSince(loadStart)
            let gate = ProgressGate()
            let budget = SpeechWorkerRequest.tokenBudget(duration: duration)
            let result = try model.generate(pcmURL: request.pcmURL, parameters: .init(maxTokens: budget, contextCache: request.mode == .quality ? .original : (request.mode == .balanced ? .eightBit : .fourBit), memoryBudget: Memory.memoryLimit, prefillStepSize: request.mode.prefillStepSize, prompt: request.prompt)) { update in
                guard gate.allow(update) else { return }
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
            if ProcessInfo.processInfo.environment["STILLNOTE_METRICS"] == "1" {
                var usage = rusage()
                getrusage(RUSAGE_SELF, &usage)
                event(["type": "metrics", "mode": request.mode.rawValue,
                       "load_seconds": loadSeconds, "generation_seconds": result.totalTime,
                       "total_seconds": Date().timeIntervalSince(loadStart),
                       "pcm_read_seconds": result.pcmReadTime, "encoding_seconds": result.encodingTime,
                       "prefill_seconds": result.prefillTime, "decoding_seconds": result.decodingTime,
                       "prompt_tokens": result.promptTokens, "output_tokens": result.generationTokens,
                       "context_cache_bytes": result.contextCacheBytes, "mlx_active_bytes": Memory.activeMemory, "mlx_cache_bytes": Memory.cacheMemory,
                       "mlx_peak_bytes": Memory.peakMemory, "peak_rss_bytes": usage.ru_maxrss])
            }
            event(["type": "result", "text": result.text])
        } catch {
            event(["type": "error", "message": error.localizedDescription])
            exit(1)
        }
    }
}

private final class ProgressGate: @unchecked Sendable {
    private var phase = -1
    private var last = Date.distantPast
    func allow(_ update: GenerationProgress) -> Bool {
        let next: Int
        let complete: Bool
        switch update {
        case .encoding(let n, let total): next = 0; complete = n == total
        case .prefill(let n, let total): next = 1; complete = n == total
        case .decoded: next = 2; complete = false
        }
        let now = Date()
        guard next != phase || complete || now.timeIntervalSince(last) >= 0.5 else { return false }
        phase = next; last = now
        return true
    }
}
