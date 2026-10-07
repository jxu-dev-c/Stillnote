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
    @Test func sendsCodexExecWithItsOutputSchemaAndReadsItsLastMessage() throws {
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
            provider: .codex, model: "gpt-5.6-luna", effort: .high, prompt: "PROMPT", schema: Summarizer.schema
        )
        #expect(response.contains("\"overview\":\"ok\""))

        let arguments = try String(contentsOf: agent.argumentsURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.count == 11)
        #expect(Array(arguments.prefix(6)) == [
            "exec", "--skip-git-repo-check", "--model", "gpt-5.6-luna", "--config", "model_reasoning_effort=\"high\"",
        ])
        #expect(arguments[6] == "--output-schema")
        #expect(arguments[7].hasSuffix("/schema.json"))
        #expect(arguments[8] == "--output-last-message")
        #expect(arguments[9].hasSuffix("/response.json"))
        #expect(arguments.last == "-")
        // The transcript travels on stdin, never as an argument.
        let stdin = try String(contentsOf: agent.stdinURL, encoding: .utf8)
        #expect(stdin == "PROMPT")
        #expect(!arguments.contains { $0.contains("PROMPT") })
    }

    @Test func readsClaudeCodeStructuredOutput() throws {
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
            provider: .claudeCode, model: "claude-sonnet-5", effort: .medium, prompt: "PROMPT",
            schema: Summarizer.schema
        )
        #expect(try Summarizer.parse(response).overview == "from claude")

        let arguments = try String(contentsOf: agent.argumentsURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(Array(arguments.prefix(8)) == [
            "-p", "--model", "claude-sonnet-5", "--effort", "medium", "--output-format", "json", "--json-schema",
        ])
        #expect(arguments.count == 9)
        #expect(arguments[8].contains("\"action_items\""))
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
        // A long transcript is still one request carrying the prompt and the whole transcript.
        for provider in SummaryProvider.allCases {
            for prompt in ["CUSTOM SUMMARY INSTRUCTIONS", " \n"] {
                try Data().write(to: agent.argumentsURL)
                try Data().write(to: agent.stdinURL)
                let settings = SummarySettings(provider: provider, agentPrompt: prompt)
                _ = try Summarizer.summarize(meeting: meeting, settings: settings,
                                            allowRemote: true, videoPath: nil)
                let stdin = try String(contentsOf: agent.stdinURL, encoding: .utf8)
                let expected = settings.resolvedAgentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                #expect(stdin.components(separatedBy: expected).count - 1 == 1)
                #expect(stdin.components(separatedBy: "Meeting content.").count - 1 == 700)
                let calls = try String(contentsOf: agent.argumentsURL, encoding: .utf8)
                #expect(calls.components(separatedBy: provider == .codex ? "exec\n" : "-p\n").count - 1 == 1)
                #expect(!stdin.contains("notes and reference links"))
            }
        }

        // The user's notes and context links travel with the transcript.
        meeting.notes = "Agenda: rollout"
        meeting.contextLinks = [ContextLink(url: "https://example.com/ticket/42", title: "Ticket 42")]
        _ = try Summarizer.summarize(meeting: meeting, settings: SummarySettings(), allowRemote: true, videoPath: nil)
        let stdin = try String(contentsOf: agent.stdinURL, encoding: .utf8)
        #expect(stdin.contains("Agenda: rollout"))
        #expect(stdin.contains("https://example.com/ticket/42"))
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
            try AgentRunner.requestJSON(provider: .codex, model: "m", effort: .low, prompt: "p", schema: Summarizer.schema)
        } throws: { error in
            let message = (error as? SummaryError)?.message ?? ""
            return message.contains("exit 7") && !message.contains("secret internal log")
        }
    }

    @Test func findsTheCLIOnTheShellPath() throws {
        let agent = try FakeAgent(script: "#!/bin/sh\nexit 0\n")
        defer { agent.cleanup() }
        let codex = agent.directory.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: agent.executable, to: codex)
        let environment = ["PATH": "/nonexistent:" + agent.directory.path]
        #expect(AgentRunner.executable(for: .codex, environment: environment) == codex.path)
        #expect(AgentRunner.executable(for: .claudeCode, environment: environment) == nil)
        // An explicit override wins, even when invalid.
        #expect(AgentRunner.executable(for: .codex, environment:
            environment.merging(["STILLNOTE_CODEX_BIN": "/nonexistent/codex"]) { _, new in new }
        ) == nil)
    }

    @Test func reportsAMissingCLI() {
        setenv("STILLNOTE_CODEX_BIN", "/nonexistent/codex", 1)
        defer { unsetenv("STILLNOTE_CODEX_BIN") }
        #expect(throws: SummaryError.self) {
            try AgentRunner.requestJSON(provider: .codex, model: "m", effort: .low, prompt: "p", schema: Summarizer.schema)
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

    /// Naming is one request with its own fixed prompt at low effort, whatever summary prompt
    /// and effort are configured, and the reply is cleaned before it becomes a title.
    @Test(arguments: [#"{"title":" \"Q4  launch review\" "}"#, #"{"title":""}"#])
    func namesAMeetingInOneRequest(reply: String) throws {
        let agent = try FakeAgent(script: """
            #!/bin/bash
            echo call >> "$FAKE_DIR/calls.txt"
            printf '%s\\n' "$@" > "$FAKE_DIR/arguments.txt"
            cat > "$FAKE_DIR/stdin.txt"
            previous=""
            for argument in "$@"; do
              if [ "$previous" = "--output-last-message" ]; then response="$argument"; fi
              previous="$argument"
            done
            printf '%s' "$REPLY_JSON" > "$response"
            """)
        defer { agent.cleanup() }
        setenv("FAKE_DIR", agent.directory.path, 1)
        setenv("REPLY_JSON", reply, 1)
        setenv("STILLNOTE_CODEX_BIN", agent.executable.path, 1)
        defer {
            unsetenv("FAKE_DIR")
            unsetenv("REPLY_JSON")
            unsetenv("STILLNOTE_CODEX_BIN")
        }
        var meeting = Meeting(id: "name", title: "Meeting", audioName: "a", language: "en",
                              speakerCount: nil, duration: 1)
        // Longer than one summary section, so a per-section request would show up as several calls.
        meeting.segments = [Segment(id: "1", start: 0, end: 1, speaker: "speaker_1",
                                   text: String(repeating: "Launch planning. ", count: 1_000))]
        let settings = SummarySettings(
            provider: .codex, reasoningEffort: .high, agentPrompt: "CUSTOM SUMMARY INSTRUCTIONS"
        )

        if reply.contains("Q4") {
            let title = try MeetingNamer.suggestTitle(meeting: meeting, settings: settings, allowRemote: true)
            #expect(title == "Q4 launch review")
        } else {
            #expect(throws: SummaryError.self) {
                try MeetingNamer.suggestTitle(meeting: meeting, settings: settings, allowRemote: true)
            }
        }
        let calls = try String(contentsOf: agent.directory.appendingPathComponent("calls.txt"), encoding: .utf8)
        #expect(calls.split(separator: "\n").count == 1)
        let stdin = try String(contentsOf: agent.stdinURL, encoding: .utf8)
        #expect(stdin.contains(MeetingNamer.instructions))
        #expect(!stdin.contains("CUSTOM SUMMARY INSTRUCTIONS"))
        let arguments = try String(contentsOf: agent.argumentsURL, encoding: .utf8)
        #expect(arguments.contains(#"model_reasoning_effort="low""#))
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
