import Foundation
import Testing
@testable import StillnoteCore

struct ModelInstallerTests {
    private let root = URL(fileURLWithPath: "/models/speech/nemotron-asr-0.6b")

    @Test func resolvesNestedCoreMLKeys() throws {
        let url = try ModelInstaller.installPath(directory: root, name: "encoder.mlmodelc/weights/weight.bin")
        #expect(url.path == "/models/speech/nemotron-asr-0.6b/encoder.mlmodelc/weights/weight.bin")
        // The parent is what install() has to create before moving the download into place.
        #expect(url.deletingLastPathComponent().lastPathComponent == "weights")
    }

    @Test func resolvesFlatKeysUnchanged() throws {
        let url = try ModelInstaller.installPath(directory: root, name: "config.json")
        #expect(url.path == "/models/speech/nemotron-asr-0.6b/config.json")
    }

    @Test(arguments: [
        "../escaped.bin",
        "encoder.mlmodelc/../../escaped.bin",
        "/etc/passwd",
        "encoder.mlmodelc//weight.bin",
        "./config.json",
        "",
    ])
    func refusesKeysThatLeaveTheInstallDirectory(name: String) {
        #expect(throws: SpeechError.self) {
            try ModelInstaller.installPath(directory: root, name: name)
        }
    }

    @Test func everyPinnedKeyResolvesInsideItsModelDirectory() throws {
        for (model, spec) in SpeechCatalog.models {
            let directory = SpeechCatalog.directory(
                modelDirectory: URL(fileURLWithPath: "/models"), model: model
            )
            for name in spec.files.keys {
                let url = try ModelInstaller.installPath(directory: directory, name: name)
                #expect(url.path.hasPrefix(directory.path + "/"))
            }
        }
    }

    @Test func diarizationModelIsNeverOfferedAsAnEngine() throws {
        let spec = try SpeechCatalog.spec(SpeechCatalog.diarizationModel)
        #expect(spec.kind == .diarization)
        #expect(SpeechCatalog.transcriptionModels[SpeechCatalog.diarizationModel] == nil)
    }

    @Test func pinnedNemotronBundlesCarryTheFilesTheRuntimeLoads() throws {
        let asr = try SpeechCatalog.spec("nemotron-asr-0.6b")
        for required in ["config.json", "vocab.json", "languages.json", "tokenizer.model",
                         "encoder.mlmodelc/coremldata.bin", "encoder.mlmodelc/model.mil",
                         "encoder.mlmodelc/weights/weight.bin",
                         "decoder.mlmodelc/coremldata.bin", "joint.mlmodelc/coremldata.bin"] {
            #expect(asr.files[required] != nil, "ASR bundle is missing \(required)")
        }
        let diarizer = try SpeechCatalog.spec(SpeechCatalog.diarizationModel)
        for required in ["config.json", "learnable_silence.f32",
                         "Nemotron3PreEncoder.mlmodelc/coremldata.bin",
                         "Nemotron3PreEncoder.mlmodelc/weights/weight.bin",
                         "Nemotron3Head.mlmodelc/coremldata.bin",
                         "Nemotron3Head.mlmodelc/weights/weight.bin"] {
            #expect(diarizer.files[required] != nil, "diarizer bundle is missing \(required)")
        }
        // Every pinned file carries a digest; ModelInstaller only chunk-downloads when it can
        // verify one, and an unverified 592 MB transfer is exactly what we must not allow.
        #expect(asr.files.values.allSatisfy { $0.sha256?.count == 64 })
        #expect(diarizer.files.values.allSatisfy { $0.sha256?.count == 64 })
    }

    /// A verified MOSS library stays on disk untouched, and nothing about it can make the
    /// Nemotron engine look installed.
    @Test func aRetiredMossLibraryNeverSatisfiesTheNewEngine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = SpeechCatalog.directory(modelDirectory: root, model: "moss-0.9b")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("0b8ba7b4".utf8).write(to: legacy.appendingPathComponent(".verified"))
        #expect(!ModelInstaller.isInstalled(modelDirectory: root, model: "moss-0.9b"))
        #expect(!ModelInstaller.isInstalled(modelDirectory: root, model: SpeechCatalog.nemotronModel))
        #expect(!ModelInstaller.isInstalled(modelDirectory: root, model: SpeechCatalog.diarizationModel))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }
}
