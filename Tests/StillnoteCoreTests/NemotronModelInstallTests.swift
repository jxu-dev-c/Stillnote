import Foundation
import Testing
@testable import StillnoteCore

/// Real verified download of the pinned Nemotron bundles. Opt-in, because it transfers about
/// 750 MB of public model files. Set `STILLNOTE_MODEL_DIR` to install somewhere reusable;
/// otherwise a temporary directory is used and removed afterwards.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STILLNOTE_MODEL_INSTALL"] == "1"),
       .serialized, .timeLimit(.minutes(30)))
struct NemotronModelInstallTests {
    private func modelDirectory() throws -> (url: URL, temporary: Bool) {
        if let override = ProcessInfo.processInfo.environment["STILLNOTE_MODEL_DIR"] {
            return (URL(fileURLWithPath: override), false)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillnote-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, true)
    }

    @Test(arguments: ["nemotron-diarize-100m", "nemotron-asr-0.6b"])
    func installsAndVerifiesPinnedBundle(model: String) async throws {
        let (directory, temporary) = try modelDirectory()
        defer { if temporary { try? FileManager.default.removeItem(at: directory) } }
        let spec = try SpeechCatalog.spec(model)

        let installer = ModelInstaller(modelDirectory: directory)
        let lastFraction = Mutex(0.0)
        try await installer.install(model: model) { progress in
            lastFraction.withLock { $0 = max($0, progress.fraction) }
        }
        #expect(lastFraction.withLock { $0 } == 1)
        #expect(ModelInstaller.isInstalled(modelDirectory: directory, model: model))

        // Every pinned file landed at its nested path with the exact recorded size.
        let installed = SpeechCatalog.directory(modelDirectory: directory, model: model)
        for (name, file) in spec.files {
            let url = try ModelInstaller.installPath(directory: installed, name: name)
            #expect(ModelInstaller.hasExactSize(url, file.size), "wrong size for \(name)")
        }
        // The compiled CoreML directories must be directories, not files.
        for bundle in spec.files.keys.compactMap({ $0.split(separator: "/").first }).map(String.init)
        where bundle.hasSuffix(".mlmodelc") {
            var isDirectory: ObjCBool = false
            let path = installed.appendingPathComponent(bundle).path
            #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue, "\(bundle) is not a directory")
        }
        // `.verified` records the revision, which is what makes a re-run a no-op.
        let verified = try String(
            contentsOf: installed.appendingPathComponent(".verified"), encoding: .utf8
        )
        #expect(verified == spec.revision)
    }

    /// Every language Stillnote offers must land on a real prompt slot.
    ///
    /// The runtime resolves a tag to `auto` when it does not recognize it, which transcribes
    /// without complaint but drops the conditioning the user asked for. The installed bundle
    /// ships bare codes for most languages and locales only for Chinese and Japanese, which
    /// is what `NemotronWorkerRequest.asrLanguage` exists to paper over. If a re-pin changes
    /// that mapping, this is what notices.
    @Test func everyOfferedLanguageResolvesToARealPromptSlot() throws {
        let (directory, temporary) = try modelDirectory()
        defer { if temporary { try? FileManager.default.removeItem(at: directory) } }
        let bundle = SpeechCatalog.directory(
            modelDirectory: directory, model: SpeechCatalog.nemotronModel
        )
        try #require(
            ModelInstaller.isInstalled(
                modelDirectory: directory, model: SpeechCatalog.nemotronModel
            ),
            "install the ASR bundle first"
        )
        let data = try Data(contentsOf: bundle.appendingPathComponent("languages.json"))
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let slots = try #require(
            (decoded?["promptDictionary"] as? [String: Int]) ?? decoded as? [String: Int]
        )
        let auto = try #require(slots["auto"])

        // The same list Settings offers, in the codes the settings document stores.
        for code in ["en", "es", "fr", "de", "it", "pt", "zh", "ja", "ko", "ar", "hi",
                     "nl", "ru"] {
            let tag = NemotronWorkerRequest.asrLanguage(code)
            // Mirrors NemotronLanguages.slot(for:): exact tag, then the language prefix.
            let slot = slots[tag]
                ?? slots[String(tag.split(separator: "-").first ?? "")]
                ?? auto
            #expect(slot != auto, "\(code) resolves to the auto slot through \(tag)")
        }
        #expect(NemotronWorkerRequest.asrLanguage("auto") == "auto")
    }
}
