import Foundation
import Testing
@testable import StillnoteCore

struct AgentEnvironmentTests {
    @Test func loadsInteractiveLoginShellExportsWithFinderEnvironment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("export STILLNOTE_LOGIN_TEST=login\n".utf8)
            .write(to: directory.appendingPathComponent(".zprofile"))
        try Data("""
            echo 'startup chatter'
            export STILLNOTE_TEST_KEY='spaces = punctuation $() `literal`'
            export PATH="/custom/cli/bin:$PATH"
            """.utf8).write(to: directory.appendingPathComponent(".zshrc"))
        let parent = ["HOME": directory.path, "ZDOTDIR": directory.path, "PATH": "/usr/bin:/bin"]
        let resolved = try AgentEnvironment.resolve(inheritShell: true, shellPath: "/bin/zsh", environment: parent)
        #expect(resolved["STILLNOTE_LOGIN_TEST"] == "login")
        #expect(resolved["STILLNOTE_TEST_KEY"] == "spaces = punctuation $() `literal`")
        #expect(resolved["PATH"]?.hasPrefix("/custom/cli/bin:") == true)
        #expect(parent["STILLNOTE_TEST_KEY"] == nil)
        let output = directory.appendingPathComponent("received")
        let result = try PosixProcess.run(executable: "/bin/sh", arguments: ["-c", "printf '%s' \"$STILLNOTE_TEST_KEY\""],
            workingDirectory: directory.path, input: Data(), stdoutURL: output, timeout: 2, environment: resolved)
        #expect(result.exitCode == 0)
        #expect(try String(contentsOf: output, encoding: .utf8) == resolved["STILLNOTE_TEST_KEY"])
    }

    @Test func appEnvironmentModeDoesNotStartAShell() throws {
        let environment = ["SOME_PROVIDER_KEY": "test-only"]
        #expect(try AgentEnvironment.resolve(inheritShell: false, shellPath: "/missing/shell",
                                            environment: environment) == environment)
    }

    @Test func invalidShellHasActionableError() {
        #expect(throws: SummaryError.self) {
            try AgentEnvironment.resolve(inheritShell: true, shellPath: "/missing/shell")
        }
    }

    @Test func migratesAndPersistsShellPreferences() throws {
        let legacy = Data(#"{"provider":"codex","model":"m","reasoning_effort":"low"}"#.utf8)
        let decoded = try JSONDecoder().decode(SummarySettings.self, from: legacy)
        #expect(decoded.inheritShellEnvironment)
        #expect(decoded.shellPath.isEmpty)
        let settings = AppSettings(summary: SummarySettings(inheritShellEnvironment: false, shellPath: "/bin/bash"))
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(AppSettings.migrating(from: object).settings == settings)
    }
}
