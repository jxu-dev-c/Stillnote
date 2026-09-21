import Foundation

/// Drives MOSS inference in a separate native Swift process. Isolation means a native model
/// crash cannot take the app down, and stopping a job is a process termination rather
/// than an unwinding of in-process GPU work.
public struct TranscriptionService: Sendable {
    public let modelDirectory: URL
    private let workerOverride: URL?

    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
        self.workerOverride = nil
    }

    init(modelDirectory: URL, workerURL: URL) {
        self.modelDirectory = modelDirectory
        self.workerOverride = workerURL
    }

    public func transcribe(
        audioURL: URL, model: String, language: String, speakerCount: Int?, hotWords: [String] = [], mode: TranscriptionMode = .quality,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> TranscriptionResult {
        _ = try SpeechCatalog.spec(model)
        if let speakerCount, !Validation.speakerCountRange.contains(speakerCount) {
            throw SpeechError.message("Speaker count must be between 1 and 20, or automatic.")
        }
        let status = SpeechStatus.current(modelDirectory: modelDirectory, model: model)
        guard status.modelInstalled else { throw SpeechError.message(status.detail) }
        guard SpeechWorkerLocator.runtimeReady(worker: workerOverride ?? SpeechWorkerLocator.workerURL()) else {
            throw SpeechError.message(SpeechWorkerLocator.repairMessage)
        }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw SpeechError.message("The local audio file could not be found.")
        }
        guard let worker = workerOverride ?? SpeechWorkerLocator.workerURL() else {
            throw SpeechError.message(SpeechWorkerLocator.repairMessage)
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
            worker: worker, pcmURL: scratch, model: model, language: language,
            speakerCount: speakerCount, hotWords: hotWords, mode: mode, progress: progress
        )
        let result = try MossParser.parse(text, duration: decoded.duration, language: language)
        progress(100, "Local transcription complete")
        return result
    }

    func workerArguments(
        pcmURL: URL, model: String, language: String, speakerCount: Int?, hotWords: [String], mode: TranscriptionMode = .quality
    ) throws -> [String] {
        var arguments = [
            pcmURL.path,
            SpeechCatalog.directory(modelDirectory: modelDirectory, model: model).path,
            language.isEmpty ? "auto" : language, String(speakerCount ?? 0),
        ]
        let words = TranscriptionSettings.normalizeHotWords(hotWords)
        if !words.isEmpty || mode != .quality {
            arguments.append(String(decoding: try JSONEncoder().encode(words), as: UTF8.self))
        }
        if mode != .quality { arguments.append(mode.rawValue) }
        return arguments
    }

    func runWorker(
        worker: URL, pcmURL: URL, model: String, language: String, speakerCount: Int?, hotWords: [String], mode: TranscriptionMode = .quality,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> String {
        let process = Process()
        process.executableURL = worker
        process.arguments = try workerArguments(
            pcmURL: pcmURL, model: model, language: language, speakerCount: speakerCount, hotWords: hotWords, mode: mode
        )
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
            guard exitCode == 0, let text = await collector.text else {
                throw SpeechError.message(
                    "The local speech worker stopped unexpectedly. Your recording is saved. "
                        + "Try again, use a shorter recording, or reinstall Stillnote."
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
actor WorkerOutput {
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
        case "error":
            error = payload["message"] as? String
        default:
            break
        }
    }
}
