import Foundation

public struct SpeechStatus: Sendable, Equatable {
    public var model: String
    public var modelName: String
    public var downloadMegabytes: Int
    public var infoURL: URL?
    public var modelInstalled: Bool
    public var runtimeReady: Bool
    public var missingRequirements: [String]
    public var installing: Bool
    public var progress: Double
    public var error: String?
    public var detail: String

    public var ready: Bool { modelInstalled && runtimeReady }
    public let engine = "MLX · Apple GPU · 8-bit decoder"

    /// A placeholder that touches no files, for use before the app has resolved its
    /// paths. Probing the filesystem during launch can deadlock against a permission
    /// prompt that cannot be shown until the app has a window.
    public static let unknown = SpeechStatus(
        model: SpeechCatalog.defaultModel, modelName: "MOSS 0.9B", downloadMegabytes: 0, infoURL: nil,
        modelInstalled: false, runtimeReady: false, missingRequirements: [], installing: false,
        progress: 0, error: nil, detail: "Checking the local speech setup…"
    )

    public static func current(
        modelDirectory: URL, model: String = SpeechCatalog.defaultModel,
        installing: Bool = false, progress: Double = 0, installDetail: String? = nil, error: String? = nil
    ) -> SpeechStatus {
        let spec = try? SpeechCatalog.spec(model)
        let installed = ModelInstaller.isInstalled(modelDirectory: modelDirectory, model: model)
        let runtime = SidecarLocator.runtimeReady()
        var missing: [String] = []
        if !runtime { missing.append("MOSS inference runtime") }

        var detail = "\(spec?.name ?? model) is ready for local transcription and speaker detection. "
            + "MLX · Apple GPU · 8-bit decoder."
        if !missing.isEmpty {
            detail = "Install the MOSS speech runtime with the project setup script."
        } else if !installed {
            detail = "Download the speech model once in Settings to enable offline transcription."
        }
        if installing, let installDetail { detail = installDetail }

        return SpeechStatus(
            model: model,
            modelName: spec?.name ?? model,
            downloadMegabytes: spec?.downloadMegabytes ?? 0,
            infoURL: spec?.infoURL,
            modelInstalled: installed,
            runtimeReady: runtime,
            missingRequirements: missing,
            installing: installing,
            progress: progress,
            error: error,
            detail: detail
        )
    }
}
