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
    @Test func sendsCodexTheHeadlessFlagsAndReadsItsLastMessage() throws {
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
            instructions: "INSTRUCTIONS", prompt: "PROMPT", schema: Summarizer.schema
        )
        #expect(response.contains("\"overview\":\"ok\""))

        let arguments = try String(contentsOf: agent.argumentsURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.first == "exec")
        #expect(arguments.contains("--sandbox"))
        #expect(arguments.contains("read-only"))
        #expect(arguments.contains("--ephemeral"))
        #expect(arguments.contains("--ignore-user-config"))
        #expect(arguments.contains("web_search=\"disabled\""))
        #expect(arguments.contains("model_reasoning_effort=\"high\""))
        #expect(arguments.contains("shell_tool"))
        #expect(arguments.last == "-")
        // The transcript travels on stdin, never as an argument.
        let stdin = try String(contentsOf: agent.stdinURL, encoding: .utf8)
        #expect(stdin == "INSTRUCTIONS\n\nPROMPT")
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
            provider: .claudeCode, model: "claude-sonnet-5", effort: .medium,
            instructions: "SYSTEM", prompt: "PROMPT", schema: Summarizer.schema
        )
        #expect(try Summarizer.parse(response).overview == "from claude")

        let arguments = try String(contentsOf: agent.argumentsURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.contains("--print"))
        #expect(arguments.contains("--disable-slash-commands"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("{\"disableAllHooks\":true}"))
        #expect(arguments.contains("--no-session-persistence"))
        #expect(arguments.contains("SYSTEM"))
        #expect(try String(contentsOf: agent.stdinURL, encoding: .utf8) == "PROMPT")
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
