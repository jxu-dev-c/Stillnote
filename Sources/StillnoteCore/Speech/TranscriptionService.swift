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
        let failed = "The local speech worker stopped unexpectedly. Your recording is saved. "
            + "Try again, use a shorter recording, or reinstall Stillnote."
        let collector = try await SpeechWorkerProcess.run(
            worker: worker,
            arguments: try workerArguments(
                pcmURL: pcmURL, model: model, language: language, speakerCount: speakerCount,
                hotWords: hotWords, mode: mode
            ),
            failureMessage: failed, progress: progress
        )
        // A zero exit with no result event is still a failure, not an empty transcript.
        guard let text = await collector.text else { throw SpeechError.message(failed) }
        return text
    }
}
