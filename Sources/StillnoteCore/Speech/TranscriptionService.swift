import Foundation

/// Drives speech inference in a separate native Swift process. Isolation means a native model
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

    /// `cleanup` removes silent head and tail and silences non-speech regions in the copy
    /// handed to the model. It never touches `audioURL`, so playback and exports keep whatever
    /// was actually recorded, and `nil` skips the pass entirely.
    public func transcribe(
        audioURL: URL, model: String, language: String, speakerCount: Int?,
        hotWords: [String] = [], cleanup: AudioCleanupSettings? = nil,
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

        let prepared = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillnote-clean-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: prepared) }
        let cleaned = try await prepare(
            decoded: decoded, into: prepared, settings: cleanup, progress: progress
        )

        try Task.checkCancellation()
        progress(8, "Loading \(status.modelName) locally")

        // Timestamps come back relative to the audio the models saw; the offset puts them
        // back on the stored recording's timeline.
        let result = try await runNemotron(
            worker: worker, pcmURL: cleaned.pcmURL, model: model, language: language,
            speakerCount: speakerCount, hotWords: hotWords, duration: decoded.duration,
            offset: cleaned.offset, progress: progress
        )
        progress(100, "Local transcription complete")
        return result
    }

    /// Builds the Nemotron worker invocation. Both model directories are resolved here, so
    /// the worker is handed verified local paths and never a model name to look up.
    func nemotronArguments(
        pcmURL: URL, model: String, language: String, speakerCount: Int?, hotWords: [String],
        geometry: NemotronWorkerRequest.Geometry = .offline
    ) throws -> [String] {
        let request = NemotronWorkerRequest(
            asrModelPath: SpeechCatalog.directory(
                modelDirectory: modelDirectory, model: model
            ).path,
            diarizerModelPath: SpeechCatalog.directory(
                modelDirectory: modelDirectory, model: SpeechCatalog.diarizationModel
            ).path,
            pcmPath: pcmURL.path,
            language: language.isEmpty ? "auto" : language,
            speakerCount: speakerCount,
            hotWords: hotWords,
            geometry: geometry
        )
        return ["nemotron", try request.encoded()]
    }

    private func runNemotron(
        worker: URL, pcmURL: URL, model: String, language: String, speakerCount: Int?,
        hotWords: [String], duration: Double, offset: Double,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> TranscriptionResult {
        let failed = "The local speech worker stopped unexpectedly. Your recording is saved. "
            + "Try again, use a shorter recording, or reinstall Stillnote."
        let collector = try await SpeechWorkerProcess.run(
            worker: worker,
            arguments: try nemotronArguments(
                pcmURL: pcmURL, model: model, language: language, speakerCount: speakerCount,
                hotWords: hotWords
            ),
            failureMessage: failed, progress: progress
        )
        // A zero exit with no transcript event is still a failure, not an empty transcript.
        guard let transcript = await collector.transcript else {
            throw SpeechError.message(failed)
        }
        progress(98, "Labeling speakers")
        return try NemotronTranscript.build(
            words: transcript.words, activity: transcript.activity, duration: duration,
            language: language, offset: offset,
            options: SpeakerAttribution.Options(
                speakerLimit: speakerCount.map(NemotronWorkerRequest.clampSpeakers)
            )
        )
    }

    /// Applies the cleanup pass, falling back to the untouched audio whenever it cannot run.
    /// A recording is worth transcribing even when silence detection is unavailable or fails,
    /// so nothing here turns a working transcription into a failed one.
    private func prepare(
        decoded: DecodedAudio, into destination: URL, settings: AudioCleanupSettings?,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> (pcmURL: URL, offset: Double) {
        let untouched = (pcmURL: decoded.pcmURL, offset: Double(0))
        guard let settings, settings.trimRecording || settings.suppressNonSpeech else { return untouched }
        let detector = workerOverride.map { SpeechActivityService(modelDirectory: modelDirectory, workerURL: $0) }
            ?? SpeechActivityService(modelDirectory: modelDirectory)
        guard detector.isAvailable else { return untouched }

        do {
            progress(3, "Detecting speech")
            let ranges = try await detector.detect(pcmURL: decoded.pcmURL, settings: settings) { fraction, _ in
                progress(3 + 0.03 * fraction, "Detecting speech")
            }
            try Task.checkCancellation()
            let plan = settings.trimRecording
                ? AudioCleanup.plan(
                    ranges: ranges, duration: decoded.duration, settings: settings, allowHeadCut: true
                )
                : CleanupPlan.noTrim(duration: decoded.duration)
            guard plan.trimsAnything || (settings.suppressNonSpeech && !ranges.isEmpty) else {
                return untouched
            }
            progress(6, "Removing silence and background noise")
            try AudioCleanup.preparePCM(
                source: decoded.pcmURL, destination: destination, ranges: ranges, plan: plan,
                suppressNonSpeech: settings.suppressNonSpeech
            )
            return (pcmURL: destination, offset: plan.head)
        } catch is CancellationError {
            throw SpeechError.cancelled
        } catch SpeechError.cancelled {
            throw SpeechError.cancelled
        } catch {
            return untouched
        }
    }
}
