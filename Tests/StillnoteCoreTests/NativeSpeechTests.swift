import Foundation
import Testing
@testable import StillnoteCore
@testable import MossTranscribeDiarize

struct NativeSpeechTests {
    @Test func preservesPromptAndValidatesArguments() throws {
        let base = try SpeechWorkerRequest(arguments: ["/a", "/m", "auto", "0"])
        let hinted = try SpeechWorkerRequest(arguments: ["/a", "/m", "en", "2", #"[" API ","示例","New York","API"]"#])
        #expect(hinted.prompt == base.prompt + " Audio language: en. Expected speakers: 2. 热词提示：API, 示例, New York")
        for args in [["/a"], ["/a", "/m", "en", "-1"], ["/a", "/m", "en", "21"],
                     ["/a", "/m", "en", "bad"], ["/a", "/m", "a b", "0"],
                     ["/a", "/m", "en", "0", "{}"]] {
            #expect(throws: Error.self) { try SpeechWorkerRequest(arguments: args) }
        }
    }

    @Test func tokenBudgetAndContextBounds() throws {
        #expect(SpeechWorkerRequest.tokenBudget(duration: 5) == 2048)
        #expect(SpeechWorkerRequest.tokenBudget(duration: 200) == 3712)
        #expect(SpeechWorkerRequest.tokenBudget(duration: 5400) == 65536)
        #expect(try GenerationPolicy.tokenLimit(requested: 2048, promptTokens: 700, contextSize: 1024) == 323)
        #expect(throws: Error.self) { try GenerationPolicy.tokenLimit(requested: 2048, promptTokens: 768, contextSize: 1024) }
        #expect(throws: Error.self) { try GenerationPolicy.tokenLimit(requested: 0, promptTokens: 0, contextSize: 1024) }
    }

    @Test func outputExhaustionNeverReturnsPartialTokens() throws {
        #expect(try GenerationPolicy.completedTokens([1, 2, 3], reachedEOS: true) == [1, 2, 3])
        #expect(throws: Error.self) { try GenerationPolicy.completedTokens([1, 2, 3], reachedEOS: false) }
    }

    @Test func repetitionGuardAllowsNaturalTextButRejectsLoops() throws {
        try GenerationPolicy.checkRepetition(Array(0..<384))
        try GenerationPolicy.checkRepetition(Array(repeating: 5, count: 383))
        #expect(throws: Error.self) { try GenerationPolicy.checkRepetition(Array(repeating: Array(0..<128), count: 3).flatMap { $0 }) }
    }

    @Test func streamingWaitsForCompleteUnicode() {
        let stream = StreamingText()
        #expect(stream.append("Hello ") == "Hello ")
        #expect(stream.append("Hello �") == nil)
        #expect(stream.append("Hello 示例") == "示例")
        #expect(stream.append("Hello 示例") == nil)
        #expect(stream.append("Hello 示例!") == "!")
    }

    @Test func legacyModelCannotSatisfyNativeReadiness() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("speech/moss-0.9b")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(SpeechCatalog.spec("moss-0.9b").revision.utf8).write(to: legacy.appendingPathComponent(".verified"))
        #expect(SpeechCatalog.directory(modelDirectory: root, model: "moss-0.9b").lastPathComponent == "moss-0.9b-mlx-8bit")
        #expect(!ModelInstaller.isInstalled(modelDirectory: root, model: "moss-0.9b"))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        let native = SpeechCatalog.directory(modelDirectory: root, model: "moss-0.9b")
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        try Data(SpeechCatalog.spec("moss-0.9b").revision.utf8).write(to: native.appendingPathComponent(".verified"))
        #expect(!ModelInstaller.isInstalled(modelDirectory: root, model: "moss-0.9b"))
    }

    @Test func corruptConfigFailsLocally() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not JSON".utf8).write(to: directory.appendingPathComponent("config.json"))
        await #expect(throws: Error.self) { try await ModelLoader.load(directory: directory) }
    }

    @Test func missingModelFailsLocally() async {
        await #expect(throws: Error.self) {
            try await ModelLoader.load(directory: URL(fileURLWithPath: "/stillnote-missing-model"))
        }
    }
}
