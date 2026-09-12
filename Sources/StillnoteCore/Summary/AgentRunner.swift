import Foundation

public struct SummaryError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct AgentAvailability: Sendable, Equatable {
    public let provider: SummaryProvider
    public let installed: Bool
    public let command: String
}

/// Headless adapters for the locally installed coding-agent CLIs. Credentials stay
/// with the CLI: Stillnote never holds an API key or endpoint.
public enum AgentRunner {
    public static let timeout: TimeInterval = 300
    static let maxResponseBytes = 1_000_000

    public static func availability() -> [AgentAvailability] {
        SummaryProvider.allCases.map {
            AgentAvailability(provider: $0, installed: executable(for: $0) != nil, command: $0.command)
        }
    }

    static func executable(
        for provider: SummaryProvider, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let override = environment[provider.environmentOverride], !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : which(override, environment)
        }
        return which(provider.command, environment)
    }

    private static func which(_ command: String, _ environment: [String: String]) -> String? {
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        // Launched from Finder, an app inherits a minimal PATH; include the usual
        // developer tool locations so an installed CLI is still found.
        let search = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/usr/local/bin", "/opt/homebrew/bin", "\(NSHomeDirectory())/.local/bin",
               "\(NSHomeDirectory())/.bun/bin", "\(NSHomeDirectory())/.npm-global/bin"]
        for directory in search {
            let candidate = directory + "/" + command
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Sends `instructions` + `prompt` to the agent and returns its JSON response text.
    public static func requestJSON(
        provider: SummaryProvider, model: String, effort: ReasoningEffort,
        instructions: String, prompt: String, schema: [String: Any]
    ) throws -> String {
        guard let executable = executable(for: provider) else {
            throw SummaryError(
                "\(provider.label) CLI was not found. Install \(provider.command), sign in, and restart "
                    + "Stillnote. For a custom installation, set \(provider.environmentOverride) to its "
                    + "executable path."
            )
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillnote-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        // Transcript content is never a command-line argument or a shell program.
        let transcriptOutput = workspace.appendingPathComponent("stdout")
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        let arguments: [String]
        let stdinText: String
        let responseURL: URL?

        switch provider {
        case .codex:
            let schemaURL = workspace.appendingPathComponent("schema.json")
            let response = workspace.appendingPathComponent("response.json")
            try schemaData.write(to: schemaURL)
            arguments = [
                "exec", "--model", model,
                "--config", "model_reasoning_effort=\"\(effort.rawValue)\"",
                "--sandbox", "read-only",
                "--skip-git-repo-check",
                "--ephemeral",
                "--ignore-user-config",
                "--config", "project_doc_max_bytes=0",
                "--config", "approval_policy=\"never\"",
                "--config", "web_search=\"disabled\"",
                "--disable", "shell_tool",
                "--disable", "unified_exec",
                "--output-schema", schemaURL.path,
                "--output-last-message", response.path,
                "--color", "never",
                "-",
            ]
            stdinText = instructions + "\n\n" + prompt
            responseURL = response
        case .claudeCode:
            arguments = [
                "--print", "--model", model, "--effort", effort.rawValue,
                "--output-format", "json",
                "--json-schema", String(decoding: schemaData, as: UTF8.self),
                "--system-prompt", instructions,
                "--tools", "",
                "--disable-slash-commands",
                "--strict-mcp-config",
                "--mcp-config", "{\"mcpServers\":{}}",
                "--setting-sources", "user",
                "--settings", "{\"disableAllHooks\":true}",
                "--permission-mode", "dontAsk",
                "--no-session-persistence",
            ]
            stdinText = prompt
            responseURL = nil
        }

        let result: PosixProcess.Result
        do {
            result = try PosixProcess.run(
                executable: executable, arguments: arguments, workingDirectory: workspace.path,
                input: Data(stdinText.utf8), stdoutURL: transcriptOutput, timeout: timeout
            )
        } catch {
            throw SummaryError(
                "Could not start \(provider.label). Check its installation and executable permissions."
            )
        }
        if result.timedOut {
            throw SummaryError(
                "\(provider.label) timed out. Retry with a shorter transcript or check the CLI connection."
            )
        }
        guard result.exitCode == 0 else {
            throw SummaryError(
                "\(provider.label) could not finish the summary (exit \(result.exitCode)). "
                    + "Check CLI sign-in, model access, usage limits, and that the CLI is up to date."
            )
        }

        let contentURL = responseURL ?? transcriptOutput
        guard let data = try? Data(contentsOf: contentURL) else {
            throw SummaryError("\(provider.label) did not return a final summary. Check model access and retry.")
        }
        guard data.count <= maxResponseBytes else {
            throw SummaryError(
                "\(provider.label) returned an unexpectedly large response. Try a shorter transcript."
            )
        }
        var text = String(decoding: data, as: UTF8.self)
        if provider == .claudeCode {
            guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SummaryError("\(provider.label) returned invalid output. Update the CLI and retry.")
            }
            if envelope["is_error"] as? Bool == true || envelope["subtype"] as? String != "success" {
                throw SummaryError(
                    "Claude Code could not complete the summary. Check CLI sign-in, model access, "
                        + "usage limits, and retry."
                )
            }
            // --json-schema returns the validated object in structured_output; older
            // releases can return the final JSON text in result.
            if let structured = envelope["structured_output"] as? [String: Any],
               let encoded = try? JSONSerialization.data(withJSONObject: structured) {
                text = String(decoding: encoded, as: UTF8.self)
            } else if let fallback = envelope["result"] as? String {
                text = fallback
            } else {
                throw SummaryError("\(provider.label) returned invalid output. Update the CLI and retry.")
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummaryError("\(provider.label) returned invalid output. Update the CLI and retry.")
        }
        return text
    }
}
