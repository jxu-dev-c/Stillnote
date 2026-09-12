import Foundation

/// Drives MOSS inference in a separate Python process. Isolation means a native model
/// crash cannot take the app down, and stopping a job is a process termination rather
/// than an unwinding of in-process GPU work.
public struct TranscriptionService: Sendable {
    public let modelDirectory: URL

    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    public func transcribe(
        audioURL: URL, model: String, language: String, speakerCount: Int?,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> TranscriptionResult {
        _ = try SpeechCatalog.spec(model)
        if let speakerCount, !Validation.speakerCountRange.contains(speakerCount) {
            throw SpeechError.message("Speaker count must be between 1 and 20, or automatic.")
        }
        let status = SpeechStatus.current(modelDirectory: modelDirectory, model: model)
        guard status.ready else { throw SpeechError.message(status.detail) }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw SpeechError.message("The local audio file could not be found.")
        }
        guard let python = SidecarLocator.pythonURL() else {
            throw SpeechError.message("Install the MOSS speech runtime with the project setup script.")
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillnote-pcm-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: scratch) }

        progress(2, "Decoding the local audio file")
        let decoded = try await AudioDecoder.decode(audioURL, to: scratch)
        if decoded.duration < 0.1 || decoded.peak < 1e-5 {
            return TranscriptionResult(
                duration: decoded.duration, language: language.isEmpty ? "auto" : language,
                speakers: [:], segments: []
            )
        }
        try Task.checkCancellation()
        progress(8, "Loading \(status.modelName) locally")

        let text = try await runWorker(
            python: python, pcmURL: scratch, model: model, language: language,
            speakerCount: speakerCount, progress: progress
        )
        let result = try MossParser.parse(text, duration: decoded.duration, language: language)
        progress(100, "Local transcription complete")
        return result
    }

    private func runWorker(
        python: URL, pcmURL: URL, model: String, language: String, speakerCount: Int?,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> String {
        let process = Process()
        process.executableURL = python
        process.arguments = [
            "-m", "moss_worker",
            pcmURL.path,
            SpeechCatalog.directory(modelDirectory: modelDirectory, model: model).path,
            language.isEmpty ? "auto" : language,
            String(speakerCount ?? 0),
        ]
        var environment = ProcessInfo.processInfo.environment
        // Inference must never reach the network or import the retired PyTorch stack.
        environment["HF_HUB_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        environment["USE_TORCH"] = "0"
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let collector = WorkerOutput(progress: progress)
        try process.run()

        return try await withTaskCancellationHandler {
            await collector.read(from: output.fileHandleForReading)
            process.waitUntilExit()
            if Task.isCancelled { throw SpeechError.cancelled }
            if let message = await collector.error { throw SpeechError.message(message) }
            guard process.terminationStatus == 0, let text = await collector.text else {
                throw SpeechError.message(
                    "The local speech worker stopped unexpectedly. Your recording is saved. "
                        + "Try again, use a shorter recording, or reinstall MOSS 0.9B."
                )
            }
            return text
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
private actor WorkerOutput {
    private static let prefix = "STILLNOTE_EVENT "
    private let progress: @Sendable (Double, String) -> Void
    private(set) var text: String?
    private(set) var error: String?

    init(progress: @escaping @Sendable (Double, String) -> Void) {
        self.progress = progress
    }

    func read(from handle: FileHandle) async {
        var buffer = Data()
        while true {
            let chunk = await Task.detached { try? handle.read(upToCount: 64 * 1024) }.value
            guard let chunk, !chunk.isEmpty else { break }
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
        case "error":
            error = payload["message"] as? String
        default:
            break
        }
    }
}
