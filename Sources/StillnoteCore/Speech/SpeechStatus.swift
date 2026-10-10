import Foundation

public struct SpeechStatus: Sendable, Equatable {
    public var model: String
    public var modelName: String
    public var downloadMegabytes: Int
    public var infoURL: URL?
    /// Every model this engine needs is installed, the diarizer included. Settings uses it to
    /// choose between Download and Repair, and transcription refuses to start without it.
    public var modelInstalled: Bool
    /// The diarizer specifically, so diagnostics can say which half is missing.
    public var diarizerInstalled: Bool
    /// The silence detection model is a separate, much smaller download. It is deliberately
    /// not part of `ready`: an install that predates it must keep transcribing.
    public var cleanupAvailable: Bool
    public var runtimeReady: Bool
    public var missingRequirements: [String]
    public var installing: Bool
    public var progress: Double
    public var error: String?
    public var detail: String

    public var ready: Bool { modelInstalled && runtimeReady }

    /// Shown in Settings.
    public var engine: String { "Native Swift · CoreML · Apple Neural Engine · INT8" }

    /// A placeholder that touches no files, for use before the app has resolved its
    /// paths. Probing the filesystem during launch can deadlock against a permission
    /// prompt that cannot be shown until the app has a window.
    public static let unknown = SpeechStatus(
        model: SpeechCatalog.defaultModel, modelName: "Nemotron 3.5 ASR 0.6B",
        downloadMegabytes: 0, infoURL: nil,
        modelInstalled: false, diarizerInstalled: false, cleanupAvailable: false,
        runtimeReady: false,
        missingRequirements: [], installing: false,
        progress: 0, error: nil, detail: "Checking the local speech setup…"
    )

    public static func current(
        modelDirectory: URL, model: String = SpeechCatalog.defaultModel,
        installing: Bool = false, progress: Double = 0, installDetail: String? = nil, error: String? = nil
    ) -> SpeechStatus {
        let spec = try? SpeechCatalog.spec(model)
        let needsDiarizer = SpeechCatalog.requiresDiarizer(model)
        let engineInstalled = ModelInstaller.isInstalled(
            modelDirectory: modelDirectory, model: model
        )
        // An engine that labels speakers itself is its own diarizer, so it reports installed
        // rather than forcing every call site to ask which engine it is looking at.
        let diarizer = needsDiarizer
            ? ModelInstaller.isInstalled(
                modelDirectory: modelDirectory, model: SpeechCatalog.diarizationModel
            )
            : engineInstalled
        let installed = engineInstalled && diarizer
        let runtime = SpeechWorkerLocator.runtimeReady()
        var missing: [String] = []
        if !runtime { missing.append("speech inference runtime") }

        var detail = "\(spec?.name ?? model) is ready for local transcription and speaker detection."
        if !missing.isEmpty {
            detail = SpeechWorkerLocator.repairMessage
        } else if !engineInstalled {
            detail = "Download the speech models once in Settings to enable offline transcription."
        } else if !diarizer {
            detail = "Download the speaker detection model in Settings to finish the setup."
        }
        if installing, let installDetail { detail = installDetail }

        return SpeechStatus(
            model: model,
            modelName: spec?.name ?? model,
            downloadMegabytes: (spec?.downloadMegabytes ?? 0)
                + (needsDiarizer
                    ? (try? SpeechCatalog.spec(SpeechCatalog.diarizationModel))?.downloadMegabytes ?? 0
                    : 0),
            infoURL: spec?.infoURL,
            modelInstalled: installed,
            diarizerInstalled: diarizer,
            cleanupAvailable: ModelInstaller.isInstalled(
                modelDirectory: modelDirectory, model: SpeechCatalog.vadModel
            ),
            runtimeReady: runtime,
            missingRequirements: missing,
            installing: installing,
            progress: progress,
            error: error,
            detail: detail
        )
    }
}
