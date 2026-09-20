import Foundation
import Testing

@testable import StillnoteCore

struct SidecarLocatorTests {
    @Test func discoveryOrderDoesNotDependOnShellPath() {
        let candidates = SidecarLocator.candidates(environment: ["STILLNOTE_MOSS_PYTHON": "/custom/python"])
        #expect(candidates[0].path == "/custom/python")
        #expect(candidates[1].path == "/opt/homebrew/opt/stillnote-runtime/libexec/bin/python")
        #expect(candidates[2].path.hasSuffix("/Stillnote/venv-moss/bin/python"))
        #expect(SidecarLocator.candidates(environment: [:]) == Array(candidates.dropFirst()))
        #expect(SidecarLocator.candidates(environment: ["STILLNOTE_MOSS_PYTHON": ""]) == Array(candidates.dropFirst()))
    }

    @Test func skipsMissingAndNonExecutableCandidates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing")
        let disabled = directory.appendingPathComponent("disabled")
        let executable = directory.appendingPathComponent("python")
        try Data().write(to: disabled)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        #expect(SidecarLocator.firstExecutable(in: [missing, disabled]) == nil)
        #expect(SidecarLocator.firstExecutable(in: [missing, disabled, executable]) == executable)
        #expect(SidecarLocator.firstExecutable(in: [executable, URL(fileURLWithPath: "/bin/sh")]) == executable)
        #expect(SidecarLocator.pythonURL(environment: ["STILLNOTE_MOSS_PYTHON": executable.path]) == executable)
        #expect(!SidecarLocator.runtimeReady(environment: ["STILLNOTE_MOSS_PYTHON": executable.path]))
    }
}
