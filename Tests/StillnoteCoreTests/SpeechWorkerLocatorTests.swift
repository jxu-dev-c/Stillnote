import Foundation
import Testing

@testable import StillnoteCore

struct SpeechWorkerLocatorTests {
    @Test func discoveryOrderDoesNotDependOnShellPath() {
        let candidates = SpeechWorkerLocator.candidates(
            executableURL: URL(fileURLWithPath: "/Applications/Stillnote.app/Contents/MacOS/Stillnote"),
            command: "/build/debug/Stillnote")
        #expect(candidates.map(\.path) == [
            "/Applications/Stillnote.app/Contents/MacOS/StillnoteSpeechWorker",
            "/build/debug/StillnoteSpeechWorker"
        ])
    }

    @Test func skipsMissingAndNonExecutableCandidates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing")
        let disabled = directory.appendingPathComponent("disabled")
        let executable = directory.appendingPathComponent("StillnoteSpeechWorker")
        try Data().write(to: disabled)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        #expect(SpeechWorkerLocator.firstExecutable(in: [missing, disabled]) == nil)
        #expect(SpeechWorkerLocator.firstExecutable(in: [missing, disabled, executable]) == executable)
        #expect(SpeechWorkerLocator.firstExecutable(in: [executable, URL(fileURLWithPath: "/bin/sh")]) == executable)
        #expect(!SpeechWorkerLocator.runtimeReady(worker: executable))
        let resources = directory.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("MTLB".utf8).write(to: resources.appendingPathComponent("mlx.metallib"))
        #expect(SpeechWorkerLocator.runtimeReady(worker: executable))
        #expect(!SpeechWorkerLocator.runtimeReady(worker: missing))
    }
}
