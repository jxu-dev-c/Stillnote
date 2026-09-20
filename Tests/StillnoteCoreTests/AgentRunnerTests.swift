import Foundation
import Testing

@testable import StillnoteCore

/// Installs a stand-in CLI so the real headless arguments, the stdin hand-off, and the
/// process-group timeout are exercised without contacting a model provider.
private struct FakeAgent {
    let directory: URL
    let executable: URL
    var argumentsURL: URL { directory.appendingPathComponent("arguments.txt") }
    var stdinURL: URL { directory.appendingPathComponent("stdin.txt") }

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillnote-agent-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("fake-agent")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@Suite(.serialized) struct AgentRunnerTests {
    @Test(arguments: [true, false]) func sendsCodexTheHeadlessFlagsAndReadsItsLastMessage(bypass: Bool) throws {
        let agent = try FakeAgent(script: """
            #!/bin/bash
            printf '%s\\n' "$@" > "$FAKE_DIR/arguments.txt"
            cat > "$FAKE_DIR/stdin.txt"
            response=""
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "--output-last-message" ]; then response="$argument"; fi
              previous="$argument"
            done
            printf '%s' '{"overview":"ok","key_points":[],"decisions":[],"action_items":[]}' > "$response"
            """)
        defer { agent.cleanup() }
        setenv("STILLNOTE_CODEX_BIN", agent.executable.path, 1)
        setenv("FAKE_DIR", agent.directory.path, 1)
        defer {
            unsetenv("STILLNOTE_CODEX_BIN")
            unsetenv("FAKE_DIR")
        }

        let response = try AgentRunner.requestJSON(
            provider: .codex, model: "gpt-5.6-luna", effort: .high,
            instructions: "INSTRUCTIONS", prompt: "PROMPT", schema: Summarizer.schema, bypassPermissions: bypass
        )
        #expect(response.contains("\"overview\":\"ok\""))

        let arguments = try String(contentsOf: agent.argumentsURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.count == (bypass ? 11 : 10))
        #expect(Array(arguments.prefix(5)) == [
            "exec", "--model", "gpt-5.6-luna", "--config", "model_reasoning_effort=\"high\"",
        ])
        #expect(arguments[5] == "--output-schema")
        #expect(arguments[6].hasSuffix("/schema.json"))
        #expect(arguments[7] == "--output-last-message")
        #expect(arguments[8].hasSuffix("/response.json"))
        #expect(arguments.contains("--dangerously-bypass-approvals-and-sandbox") == bypass)
        #expect(arguments.last == "-")
        // The transcript travels on stdin, never as an argument.
        let stdin = try String(contentsOf: agent.stdinURL, encoding: .utf8)
        #expect(stdin == "INSTRUCTIONS\n\nPROMPT")
        #expect(!arguments.contains { $0.contains("PROMPT") })
    }

    @Test(arguments: [true, false]) func readsClaudeCodeStructuredOutput(bypass: Bool) throws {
        let agent = try FakeAgent(script: """
            #!/bin/bash
            printf '%s\\n' "$@" > "$FAKE_DIR/arguments.txt"
            cat > "$FAKE_DIR/stdin.txt"
            printf '%s' '{"subtype":"success","is_error":false,"structured_output":{"overview":"from claude","key_points":[],"decisions":[],"action_items":[]}}'
            """)
        defer { agent.cleanup() }
        setenv("STILLNOTE_CLAUDE_BIN", agent.executable.path, 1)
        setenv("FAKE_DIR", agent.directory.path, 1)
        defer {
            unsetenv("STILLNOTE_CLAUDE_BIN")
            unsetenv("FAKE_DIR")
        }

        let response = try AgentRunner.requestJSON(
            provider: .claudeCode, model: "claude-sonnet-5", effort: .medium,
            instructions: "SYSTEM", prompt: "PROMPT", schema: Summarizer.schema, bypassPermissions: bypass
        )
        #expect(try Summarizer.parse(response).overview == "from claude")

        let arguments = try String(contentsOf: agent.argumentsURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.contains("--dangerously-skip-permissions") == bypass)
        #expect(arguments.contains("--permission-mode") == !bypass)
        #expect(arguments.contains("dontAsk") == !bypass)
        #expect(arguments.contains("--print"))
        #expect(arguments.contains("--disable-slash-commands"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("{\"disableAllHooks\":true}"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("SYSTEM"))
        #expect(try String(contentsOf: agent.stdinURL, encoding: .utf8) == "PROMPT")
    }

    @Test func summaryDeliversConfiguredPromptToBothProviders() throws {
        let agent = try FakeAgent(script: """
            #!/bin/bash
            printf '%s\\n' "$@" >> "$FAKE_DIR/arguments.txt"
            cat >> "$FAKE_DIR/stdin.txt"
            response=""
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "--output-last-message" ]; then response="$argument"; fi
              previous="$argument"
            done
            if [ -n "$response" ]; then
              printf '%s' '{"overview":"ok","key_points":[],"decisions":[],"action_items":[]}' > "$response"
            else
              printf '%s' '{"subtype":"success","is_error":false,"structured_output":{"overview":"ok","key_points":[],"decisions":[],"action_items":[]}}'
            fi
            """)
        defer { agent.cleanup() }
        setenv("FAKE_DIR", agent.directory.path, 1)
        setenv("STILLNOTE_CODEX_BIN", agent.executable.path, 1)
        setenv("STILLNOTE_CLAUDE_BIN", agent.executable.path, 1)
        defer {
            unsetenv("FAKE_DIR")
            unsetenv("STILLNOTE_CODEX_BIN")
            unsetenv("STILLNOTE_CLAUDE_BIN")
        }
        var meeting = Meeting(id: "prompt", title: "Test", audioName: "a", language: "en",
                              speakerCount: nil, duration: 1)
        meeting.segments = [Segment(id: "1", start: 0, end: 1, speaker: "speaker_1",
                                   text: String(repeating: "Meeting content. ", count: 700))]
        for provider in SummaryProvider.allCases {
            for prompt in ["CUSTOM SUMMARY INSTRUCTIONS", " \n"] {
                try Data().write(to: agent.argumentsURL)
                try Data().write(to: agent.stdinURL)
                let bypass = prompt == "CUSTOM SUMMARY INSTRUCTIONS"
                let settings = SummarySettings(provider: provider, agentPrompt: prompt, bypassPermissions: bypass)
                _ = try Summarizer.summarize(meeting: meeting, settings: settings,
                                            allowRemote: true, videoPath: nil)
                let captured = try String(contentsOf: provider == .codex ? agent.stdinURL : agent.argumentsURL,
                                          encoding: .utf8)
                let count = captured.components(separatedBy: settings.resolvedAgentPrompt).count - 1
                #expect(count == 2)
                let args = try String(contentsOf: agent.argumentsURL, encoding: .utf8)
                let flag = provider == .codex ? "--dangerously-bypass-approvals-and-sandbox" : "--dangerously-skip-permissions"
                #expect(args.contains(flag) == bypass)
            }
        }
    }

    /// A failing CLI produces an actionable message, never its raw output.
    @Test func surfacesAFailedAgentWithoutItsOutput() throws {
        let agent = try FakeAgent(script: """
            #!/bin/bash
            cat > /dev/null
            echo 'secret internal log'
            exit 7
            """)
        defer { agent.cleanup() }
        setenv("STILLNOTE_CODEX_BIN", agent.executable.path, 1)
        defer { unsetenv("STILLNOTE_CODEX_BIN") }

        #expect {
            try AgentRunner.requestJSON(
                provider: .codex, model: "m", effort: .low, instructions: "i", prompt: "p",
                schema: Summarizer.schema
            )
        } throws: { error in
            let message = (error as? SummaryError)?.message ?? ""
            return message.contains("exit 7") && !message.contains("secret internal log")
        }
    }

    @Test func namesMissingEnvironmentVariableWithoutLeakingOutput() throws {
        let agent = try FakeAgent(script: """
            #!/bin/bash
            cat > /dev/null
            echo 'secret internal log' >&2
            echo 'ERROR: Missing environment variable: `CUSTOM_PROVIDER_KEY`.' >&2
            exit 1
            """)
        defer { agent.cleanup() }
        setenv("STILLNOTE_CODEX_BIN", agent.executable.path, 1)
        defer { unsetenv("STILLNOTE_CODEX_BIN") }
        #expect {
            try AgentRunner.requestJSON(provider: .codex, model: "m", effort: .low,
                instructions: "i", prompt: "p", schema: Summarizer.schema, inheritShellEnvironment: false)
        } throws: { error in
            let message = error.localizedDescription
            return message.contains("CUSTOM_PROVIDER_KEY") && message.contains("Settings")
                && !message.contains("secret internal log")
        }
    }

    @Test func discoversNvmCLIWithFinderPathAndRunsItsSiblingRuntime() throws {
        let agent = try FakeAgent(script: "#!/bin/sh\nexit 0\n")
        defer { agent.cleanup() }
        for version in ["v20.9.0", "v20.19.3"] {
            let bin = agent.directory.appendingPathComponent("versions/node/" + version + "/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            for (name, script) in [
                ("codex", "#!/usr/bin/env stillnote-test-runtime\n"),
                ("stillnote-test-runtime", "#!/bin/sh\nprintf runtime-ok\n")
            ] {
                let file = bin.appendingPathComponent(name)
                try Data(script.utf8).write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            }
        }
        let environment = ["PATH": "/usr/bin:/bin", "NVM_DIR": agent.directory.path]
        // Explicit overrides must still win, even when invalid.
        #expect(AgentRunner.executable(for: .codex, environment:
            environment.merging(["STILLNOTE_CODEX_BIN": "/nonexistent/codex"]) { _, new in new }
        ) == nil)
        let executable = try #require(AgentRunner.executable(for: .codex, environment: environment))
        #expect(executable.hasSuffix("v20.19.3/bin/codex"))
        let output = agent.directory.appendingPathComponent("output")
        let result = try PosixProcess.run(
            executable: executable, arguments: [], workingDirectory: agent.directory.path,
            input: Data(), stdoutURL: output, timeout: 5
        )
        #expect(result.exitCode == 0)
        #expect(try String(contentsOf: output, encoding: .utf8) == "runtime-ok")
    }

    @Test func reportsAMissingCLI() {
        setenv("STILLNOTE_CODEX_BIN", "/nonexistent/codex", 1)
        defer { unsetenv("STILLNOTE_CODEX_BIN") }
        #expect(throws: SummaryError.self) {
            try AgentRunner.requestJSON(
                provider: .codex, model: "m", effort: .low, instructions: "i", prompt: "p",
                schema: Summarizer.schema
            )
        }
    }

    /// A timeout must kill the whole process group, not just the CLI, so a child does
    /// not outlive the temporary workspace it was given.
    @Test func killsTheProcessGroupOnTimeout() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillnote-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("child-survived.txt")
        let script = directory.appendingPathComponent("sleeper")
        try Data("""
            #!/bin/bash
            ( sleep 5; touch "\(marker.path)" ) &
            sleep 5
            """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let result = try PosixProcess.run(
            executable: script.path, arguments: [], workingDirectory: directory.path,
            input: Data(), stdoutURL: directory.appendingPathComponent("out"), timeout: 0.5
        )
        #expect(result.timedOut)
        Thread.sleep(forTimeInterval: 1.5)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

@Suite struct LinkMetadataTests {
    @Test func prefersTheTitleElement() {
        let html = "<html><head><title>  Design   Spec </title>"
            + "<meta property=\"og:title\" content=\"Ignored\"></head><body>x</body></html>"
        #expect(LinkMetadata.title(fromHTML: html) == "Design Spec")
    }

    @Test func fallsBackToOpenGraphAndDecodesEntities() {
        let html = "<html><head><meta name=\"twitter:title\" content=\"Tom &amp; Jerry\"></head></html>"
        #expect(LinkMetadata.title(fromHTML: html) == "Tom & Jerry")
    }

    @Test func returnsEmptyWhenNoTitleExists() {
        #expect(LinkMetadata.title(fromHTML: "<html><body>nothing</body></html>").isEmpty)
    }

    /// Non-public schemes and credential-bearing URLs are never fetched.
    @Test func neverFetchesNonPublicSchemes() async {
        #expect(await LinkMetadata.pageTitle("file:///etc/passwd").isEmpty)
        #expect(await LinkMetadata.pageTitle("https://user:pass@example.com").isEmpty)
    }
}
