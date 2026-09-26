import Foundation

/// Finds the speech in a decoded recording by running the bundled worker's silence
/// detector. The model is small, but it is MLX work, so it stays behind the same process
/// boundary as transcription and is serialized with it by `JobQueue`.
public struct SpeechActivityService: Sendable {
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

    /// Whether the detector can run at all. Cleanup is skipped rather than blocking a save
    /// or a transcription when the supporting model has not been downloaded.
    public var isAvailable: Bool {
        guard ModelInstaller.isInstalled(modelDirectory: modelDirectory, model: SpeechCatalog.vadModel),
              let worker = workerOverride ?? SpeechWorkerLocator.workerURL()
        else { return false }
        return SpeechWorkerLocator.runtimeReady(worker: worker)
    }

    /// `pcmURL` is 16 kHz mono float32, as `AudioDecoder` writes it.
    public func detect(
        pcmURL: URL, settings: AudioCleanupSettings,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> [SpeechRange] {
        guard let worker = workerOverride ?? SpeechWorkerLocator.workerURL(),
              SpeechWorkerLocator.runtimeReady(worker: worker)
        else { throw SpeechError.message(SpeechWorkerLocator.repairMessage) }
        guard ModelInstaller.isInstalled(modelDirectory: modelDirectory, model: SpeechCatalog.vadModel) else {
            throw SpeechError.message(
                "Download the silence detection model in Settings to remove silence and background noise."
            )
        }
        guard FileManager.default.fileExists(atPath: pcmURL.path) else {
            throw SpeechError.message("The decoded audio could not be found.")
        }

        let collector = try await SpeechWorkerProcess.run(
            worker: worker,
            arguments: [
                "vad", pcmURL.path,
                SpeechCatalog.directory(modelDirectory: modelDirectory, model: SpeechCatalog.vadModel).path,
                String(settings.sensitivity.threshold),
            ],
            failureMessage: "Silence detection stopped unexpectedly. Your recording is unchanged.",
            progress: progress
        )
        guard let ranges = await collector.ranges else {
            throw SpeechError.message("Silence detection stopped unexpectedly. Your recording is unchanged.")
        }
        return ranges.sorted { $0.start < $1.start }
    }
}
