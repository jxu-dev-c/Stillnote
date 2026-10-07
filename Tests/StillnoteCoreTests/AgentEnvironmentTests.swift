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
        let resolved = try AgentEnvironment.resolve(shell: "/bin/zsh", environment: parent)
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

    @Test func invalidShellHasActionableError() {
        #expect(throws: SummaryError.self) { try AgentEnvironment.resolve(shell: "/missing/shell") }
    }

    /// The retired permission and shell options are dropped from stored settings.
    @Test func dropsRetiredSummaryOptions() throws {
        let stored: [String: Any] = ["summary": [
            "provider": "codex", "model": "m", "reasoning_effort": "low", "agent_prompt": "Be brief.",
            "bypass_permissions": false, "inherit_shell_environment": false, "shell_path": "/bin/bash",
        ]]
        let migrated = AppSettings.migrating(from: stored)
        #expect(migrated.changed)
        #expect(migrated.settings.summary == SummarySettings(provider: .codex, model: "m", reasoningEffort: .low,
                                                             agentPrompt: "Be brief."))
    }
}
