import Foundation

/// Computes voiceprints with the bundled worker's speaker-embedding model. Inference stays
/// behind the same process boundary as transcription, so a native crash cannot take the app
/// down and the model's memory is returned as soon as a meeting is done.
public struct VoiceEmbeddingService: Sendable {
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

    public var modelRevision: String {
        (try? SpeechCatalog.spec(SpeechCatalog.speakerModel))?.revision ?? "unknown"
    }

    public var isInstalled: Bool {
        ModelInstaller.isInstalled(modelDirectory: modelDirectory, model: SpeechCatalog.speakerModel)
    }

    public var isAvailable: Bool {
        guard isInstalled, let worker = workerOverride ?? SpeechWorkerLocator.workerURL() else { return false }
        return SpeechWorkerLocator.runtimeReady(worker: worker)
    }

    /// One unit-length embedding per window, in order. `pcmURL` is 16 kHz mono float32 on
    /// the stored recording's timeline, as `AudioDecoder` writes it.
    public func embed(
        pcmURL: URL, windows: [VoiceWindow],
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> [[Float]] {
        guard !windows.isEmpty else { return [] }
        guard let worker = workerOverride ?? SpeechWorkerLocator.workerURL(),
              SpeechWorkerLocator.runtimeReady(worker: worker)
        else { throw SpeechError.message(SpeechWorkerLocator.repairMessage) }
        guard isInstalled else {
            throw SpeechError.message("Download the voice recognition model to learn voices.")
        }
        let request = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillnote-voice-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: request) }
        let data = try JSONEncoder().encode(windows)
        guard FileManager.default.createFile(atPath: request.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SpeechError.message("Voice recognition could not prepare its input.")
        }
        let failure = "Voice recognition stopped unexpectedly. Your meetings are unchanged."
        let collector = try await SpeechWorkerProcess.run(
            worker: worker,
            arguments: [
                "embed", pcmURL.path,
                SpeechCatalog.directory(modelDirectory: modelDirectory, model: SpeechCatalog.speakerModel).path,
                request.path,
            ],
            failureMessage: failure, progress: progress
        )
        guard let vectors = await collector.embeddings, vectors.count == windows.count else {
            throw SpeechError.message(failure)
        }
        return vectors
    }

    /// Decodes a meeting's recording and computes a voiceprint for each of its labels.
    public func voiceprints(
        for meeting: Meeting, audioURL: URL,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> MeetingVoiceprints {
        let fingerprint = VoiceRecognition.fingerprint(of: meeting, modelRevision: modelRevision)
        let plan = VoiceWindowPlanner.plan(segments: meeting.segments, duration: meeting.duration)
        var result = MeetingVoiceprints(
            meetingID: meeting.id, fingerprint: fingerprint, modelRevision: modelRevision,
            voiceprints: [], tooShort: plan.tooShort
        )
        guard !plan.windows.isEmpty else { return result }
        let pcm = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillnote-voice-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: pcm) }
        progress(0, "Reading audio")
        _ = try await AudioDecoder.decode(audioURL, to: pcm)
        try Task.checkCancellation()
        let vectors = try await embed(pcmURL: pcm, windows: plan.windows, progress: progress)
        result.voiceprints = Voiceprint.aggregate(windows: plan.windows, embeddings: vectors)
        let embedded = Set(result.voiceprints.map(\.speaker))
        result.tooShort = Array(Set(plan.tooShort).union(plan.speechSeconds.keys.filter { !embedded.contains($0) })).sorted()
        return result
    }
}
