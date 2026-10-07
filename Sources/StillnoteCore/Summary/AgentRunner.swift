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

/// Runs the user's own coding-agent CLI as if typed in their terminal: `codex exec` or
/// `claude -p`, with the CLI's native JSON-schema output. The CLI's own config — sign-in,
/// skills, MCP servers, permissions — applies unchanged; Stillnote holds no credentials.
public enum AgentRunner {
    public static let timeout: TimeInterval = 600
    static let maxResponseBytes = 1_000_000

    public static func availability() -> [AgentAvailability] {
        let environment = (try? AgentEnvironment.resolve()) ?? ProcessInfo.processInfo.environment
        return SummaryProvider.allCases.map {
            AgentAvailability(provider: $0, installed: executable(for: $0, environment: environment) != nil, command: $0.command)
        }
    }

    static func executable(for provider: SummaryProvider, environment: [String: String]) -> String? {
        let command = environment[provider.environmentOverride].flatMap { $0.isEmpty ? nil : $0 } ?? provider.command
        if command.contains("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        return (environment["PATH"] ?? "").split(separator: ":")
            .map { "\($0)/\(command)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Sends `prompt` on stdin and returns the JSON object text the CLI produced for `schema`.
    public static func requestJSON(
        provider: SummaryProvider, model: String, effort: ReasoningEffort, prompt: String, schema: [String: Any]
    ) throws -> String {
        let environment = try AgentEnvironment.resolve()
        guard let executable = executable(for: provider, environment: environment) else {
            throw SummaryError(
                "\(provider.label) CLI was not found on your shell's PATH. Install \(provider.command), "
                    + "sign in, and retry."
            )
        }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillnote-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        let stdout = workspace.appendingPathComponent("stdout")
        let response = workspace.appendingPathComponent("response.json")
        let arguments: [String]
        switch provider {
        case .codex:
            let schemaURL = workspace.appendingPathComponent("schema.json")
            try schemaData.write(to: schemaURL)
            arguments = [
                "exec", "--skip-git-repo-check", "--model", model,
                "--config", "model_reasoning_effort=\"\(effort.rawValue)\"",
                "--output-schema", schemaURL.path, "--output-last-message", response.path, "-",
            ]
        case .claudeCode:
            arguments = [
                "-p", "--model", model, "--effort", effort.rawValue,
                "--output-format", "json", "--json-schema", String(decoding: schemaData, as: UTF8.self),
            ]
        }

        let result: PosixProcess.Result
        do {
            // The transcript travels on stdin, never as an argument.
            result = try PosixProcess.run(
                executable: executable, arguments: arguments, workingDirectory: workspace.path,
                input: Data(prompt.utf8), stdoutURL: stdout, timeout: timeout, environment: environment,
                stderrURL: workspace.appendingPathComponent("stderr")
            )
        } catch {
            throw SummaryError("Could not start \(provider.label). Check its installation.")
        }
        if result.timedOut {
            throw SummaryError("\(provider.label) timed out. Check the CLI connection and retry.")
        }
        guard result.exitCode == 0 else {
            throw SummaryError(
                "\(provider.label) failed (exit \(result.exitCode)). Run `\(provider.command)` in a terminal "
                    + "to check sign-in, model access, and usage limits."
            )
        }

        guard let data = try? Data(contentsOf: provider == .codex ? response : stdout), !data.isEmpty else {
            throw SummaryError("\(provider.label) returned no output. Retry.")
        }
        guard data.count <= maxResponseBytes else {
            throw SummaryError("\(provider.label) returned an unexpectedly large response.")
        }
        guard provider == .claudeCode else { return String(decoding: data, as: UTF8.self) }

        // `claude -p --output-format json` wraps the schema-validated object in an envelope.
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["is_error"] as? Bool != true,
              let structured = envelope["structured_output"] as? [String: Any],
              let encoded = try? JSONSerialization.data(withJSONObject: structured)
        else {
            throw SummaryError(
                "Claude Code did not return the requested JSON. Check CLI sign-in, model access, and retry."
            )
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}
