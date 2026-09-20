import Foundation
import Testing

@testable import StillnoteCore

@Suite struct HotWordsTests {
    @Test func legacySettingsAndNormalization() throws {
        let legacy = Data(#"{"model":"moss-0.9b","language":"auto"}"#.utf8)
        #expect(try JSONDecoder().decode(TranscriptionSettings.self, from: legacy).hotWords.isEmpty)
        #expect(AppSettings.migrating(from: [:]).settings.transcription.hotWords.isEmpty)
        let words = TranscriptionSettings.normalizeHotWords(["  OpenMOSS ", "", "\t", "示例", "New York", "OpenMOSS", "openmoss"])
        #expect(words == ["OpenMOSS", "示例", "New York", "openmoss"])
        let settings = TranscriptionSettings(hotWords: words)
        let encoded = try JSONEncoder().encode(settings)
        #expect(String(decoding: encoded, as: UTF8.self).contains("hot_words"))
        #expect(try JSONDecoder().decode(TranscriptionSettings.self, from: encoded) == settings)
    }

    @Test func persistsMigratesAndClears() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        var settings = AppSettings()
        settings.transcription.hotWords = [" API ", "New York", "示例", "API", ""]
        let saved = try await store.saveSettings(settings)
        #expect(saved.transcription.hotWords == ["API", "New York", "示例"])
        let reopened = try Store(paths: paths)
        #expect(try await reopened.settings() == saved)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        #expect(AppSettings.migrating(from: object).settings == saved)
        settings = saved
        settings.transcription.hotWords = []
        try await reopened.saveSettings(settings)
        #expect(try await store.settings().transcription.hotWords.isEmpty)
    }

    @Test func workerArgumentsPreserveWordsAndEmptyCompatibility() throws {
        let service = TranscriptionService(modelDirectory: URL(fileURLWithPath: "/models"))
        let pcm = URL(fileURLWithPath: "/audio file.f32")
        let empty = try service.workerArguments(pcmURL: pcm, model: SpeechCatalog.defaultModel,
                                                language: "", speakerCount: nil, hotWords: [])
        #expect(empty.count == 4)
        #expect(Array(empty.suffix(2)) == ["auto", "0"])
        var settings = TranscriptionSettings(hotWords: ["示例", "New York", "a, b", "say \"hi\"", "$HOME"])
        let queuedWords = settings.hotWords
        settings.hotWords = ["Changed later"]
        let arguments = try service.workerArguments(pcmURL: pcm, model: SpeechCatalog.defaultModel,
                                                    language: "en", speakerCount: 2, hotWords: queuedWords)
        #expect(arguments.count == 5)
        #expect(arguments[0] == pcm.path)
        #expect(try JSONDecoder().decode([String].self, from: Data(arguments[4].utf8)) == queuedWords)
        #expect(arguments[2] == "en")
        #expect(arguments[3] == "2")
    }

}
