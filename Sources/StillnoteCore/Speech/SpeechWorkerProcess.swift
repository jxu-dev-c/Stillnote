import Foundation

/// Runs the bundled worker and collects its event stream. Transcription and silence
/// detection share this so process isolation, the environment hardening, and the
/// cancellation escalation are defined exactly once.
enum SpeechWorkerProcess {
    static func run(
        worker: URL, arguments: [String], failureMessage: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> WorkerOutput {
        let process = Process()
        process.executableURL = worker
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Defense in depth: the helper only loads an already verified local directory.
        environment["HF_HUB_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let collector = WorkerOutput(progress: progress)
        // Register before launch so even an immediately exiting worker is observed.
        // waitUntilExit can strand a cooperative executor in a Foundation run loop.
        let (exitEvents, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { ended in
            exitContinuation.yield(ended.terminationStatus)
            exitContinuation.finish()
        }
        do { try process.run() }
        catch { exitContinuation.finish(); throw error }

        return try await withTaskCancellationHandler {
            await collector.read(from: output.fileHandleForReading)
            var exitCode: Int32?
            for await code in exitEvents { exitCode = code; break }
            if Task.isCancelled { throw SpeechError.cancelled }
            if let message = await collector.error {
                throw SpeechError.message(message)
            }
            guard exitCode == 0 else { throw SpeechError.message(failureMessage) }
            return collector
        } onCancel: {
            guard process.isRunning else { return }
            process.terminate()
            // Give MLX two seconds to release the GPU before forcing the issue.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

/// Parses the worker's newline-delimited event stream. Native libraries may print
/// diagnostics on the same pipe; anything without the event prefix is ignored and is
/// never surfaced as meeting content or as an error message.
actor WorkerOutput {
    private static let prefix = "STILLNOTE_EVENT "
    private let progress: @Sendable (Double, String) -> Void
    private(set) var text: String?
    private(set) var error: String?
    private(set) var ranges: [SpeechRange]?

    init(progress: @escaping @Sendable (Double, String) -> Void) {
        self.progress = progress
    }

    func read(from handle: FileHandle) async {
        var buffer = Data()
        while true {
            // availableData returns as soon as pipe bytes arrive. A fixed-size
            // read can wait for the entire buffer, hiding progress until exit.
            let chunk = await Task.detached { handle.availableData }.value
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                consume(line: line)
            }
        }
        if !buffer.isEmpty { consume(line: String(decoding: buffer, as: UTF8.self)) }
    }

    private func consume(line: String) {
        guard line.hasPrefix(Self.prefix),
              let payload = try? JSONSerialization.jsonObject(
                  with: Data(line.dropFirst(Self.prefix.count).utf8)
              ) as? [String: Any]
        else { return }
        switch payload["type"] as? String {
        case "progress":
            progress(payload["progress"] as? Double ?? 0, payload["detail"] as? String ?? "")
        case "result":
            text = payload["text"] as? String ?? ""
        case "ranges":
            // Pairs that are not two finite, ordered numbers are ignored rather than
            // becoming a range that could silence or truncate the wrong audio.
            // Coerced element by element: one malformed pair must not discard the rest,
            // and a pair that is not two finite, ordered numbers is dropped rather than
            // becoming a range that silences or truncates the wrong audio.
            ranges = (payload["ranges"] as? [Any] ?? []).compactMap { entry in
                guard let pair = entry as? [Any], pair.count == 2,
                      let start = (pair[0] as? NSNumber)?.doubleValue,
                      let end = (pair[1] as? NSNumber)?.doubleValue,
                      start.isFinite, end.isFinite, end >= start
                else { return nil }
                return SpeechRange(start: start, end: end)
            }
        case "error":
            error = payload["message"] as? String
        default:
            break
        }
    }
}
