import Foundation

/// One command's shape. The catalog is the single description of the CLI: it drives parsing,
/// `--help`, and `stillnote help --json`, which `scripts/check-skill.sh` reads to prove the
/// published skill documents only commands that exist.
public struct CommandSpec: Codable, Hashable, Sendable {
    public var path: [String]
    public var summary: String
    /// Positional names in order; a trailing `?` marks one as optional.
    public var positionals: [String]
    /// Long option names that consume the following token.
    public var valueOptions: [String]
    /// Long option names that stand alone.
    public var booleanOptions: [String]
    /// Whether the command needs the running app: it writes, or it drives capture.
    public var requiresApp: Bool
    /// How long the CLI waits for a reply. Saving a recording mixes and trims audio.
    public var timeout: Double

    enum CodingKeys: String, CodingKey {
        case path, summary, positionals
        case valueOptions = "value_options"
        case booleanOptions = "boolean_options"
        case requiresApp = "requires_app"
        case timeout
    }

    public init(
        path: [String], summary: String, positionals: [String] = [], valueOptions: [String] = [],
        booleanOptions: [String] = [], requiresApp: Bool = false, timeout: Double = 60
    ) {
        self.path = path
        self.summary = summary
        self.positionals = positionals
        self.valueOptions = valueOptions
        self.booleanOptions = booleanOptions
        self.requiresApp = requiresApp
        self.timeout = timeout
    }

    public var name: String { path.joined(separator: " ") }

    public var requiredPositionals: Int { positionals.filter { !$0.hasSuffix("?") }.count }

    public var usage: String {
        var parts = ["stillnote", name]
        parts += positionals.map { $0.hasSuffix("?") ? "[<\($0.dropLast())>]" : "<\($0)>" }
        parts += valueOptions.sorted().map { "[--\($0) <value>]" }
        parts += booleanOptions.sorted().map { "[--\($0)]" }
        return parts.joined(separator: " ")
    }
}

/// A parsed invocation: which command, its arguments, and the presentation choices that stay
/// on the client side.
public struct CLIInvocation: Sendable {
    public var spec: CommandSpec
    public var request: CLIRequest
    public var wantsJSON: Bool
    public var timeout: Double

    public init(spec: CommandSpec, request: CLIRequest, wantsJSON: Bool, timeout: Double) {
        self.spec = spec
        self.request = request
        self.wantsJSON = wantsJSON
        self.timeout = timeout
    }
}

public enum CommandCatalog {
    /// Options every command accepts. `--json` and `--timeout` are handled by the client and
    /// never reach the app.
    public static let globalBooleans = ["json", "help"]
    public static let globalValues = ["timeout"]

    public static let commands: [CommandSpec] = [
        CommandSpec(
            path: ["help"],
            summary: "List every command, or describe one.",
            positionals: ["command?"]
        ),
        CommandSpec(
            path: ["status"],
            summary: "Report whether the app is running, and what it is doing."
        ),
        CommandSpec(
            path: ["list"],
            summary: "List meetings, newest first.",
            valueOptions: ["limit", "since", "until", "status", "speaker"]
        ),
        CommandSpec(
            path: ["show"],
            summary: "Show one meeting: its summary, notes, speakers, and optionally its transcript.",
            positionals: ["meeting"],
            valueOptions: ["speaker"],
            booleanOptions: ["segments"]
        ),
        CommandSpec(
            path: ["search"],
            summary: "Search titles, transcripts, summaries, and notes.",
            positionals: ["query"],
            valueOptions: ["in", "speaker", "since", "until", "limit", "context"]
        ),
        CommandSpec(
            path: ["export"],
            summary: "Export one meeting as md, txt, srt, or json.",
            positionals: ["meeting"],
            valueOptions: ["format", "out"]
        ),
        CommandSpec(
            path: ["summary", "show"],
            summary: "Show one meeting's summary.",
            positionals: ["meeting"]
        ),
        CommandSpec(
            path: ["summary", "set"],
            summary: "Replace a summary's overview, or the whole summary from JSON on stdin.",
            positionals: ["meeting"],
            valueOptions: ["overview"],
            booleanOptions: ["json-stdin"],
            requiresApp: true
        ),
        CommandSpec(
            path: ["notes", "show"],
            summary: "Show one meeting's notes.",
            positionals: ["meeting"]
        ),
        CommandSpec(
            path: ["notes", "set"],
            summary: "Replace one meeting's notes.",
            positionals: ["meeting"],
            valueOptions: ["text"],
            booleanOptions: ["stdin"],
            requiresApp: true
        ),
        CommandSpec(
            path: ["transcript", "replace"],
            summary: "Replace text across transcripts. Needs --meeting or --all.",
            positionals: ["find", "replacement"],
            valueOptions: ["meeting"],
            booleanOptions: ["all", "regex", "ignore-case", "whole-word", "dry-run"],
            requiresApp: true
        ),
        CommandSpec(
            path: ["transcript", "set"],
            summary: "Replace one transcript segment's text, and optionally its speaker.",
            positionals: ["meeting"],
            valueOptions: ["segment", "text", "speaker"],
            requiresApp: true
        ),
        CommandSpec(
            path: ["speaker", "rename"],
            summary: "Rename a speaker in one meeting.",
            positionals: ["meeting"],
            valueOptions: ["speaker", "name"],
            requiresApp: true
        ),
        CommandSpec(
            path: ["transcribe"],
            summary: "Queue local transcription for one meeting.",
            positionals: ["meeting"],
            valueOptions: ["language", "speakers"],
            requiresApp: true
        ),
        CommandSpec(
            path: ["summarize"],
            summary: "Summarize one meeting with the configured agent. Needs --allow-remote.",
            positionals: ["meeting"],
            booleanOptions: ["allow-remote"],
            requiresApp: true
        ),
        CommandSpec(
            path: ["record", "status"],
            summary: "Report the current recording session.",
            requiresApp: true
        ),
        CommandSpec(
            path: ["record", "start"],
            summary: "Start a recording.",
            valueOptions: ["title", "mic", "screen", "language", "speakers"],
            booleanOptions: ["no-system-audio", "screen-video"],
            requiresApp: true
        ),
        CommandSpec(
            path: ["record", "stop"],
            summary: "Stop and save the current recording, then queue transcription.",
            booleanOptions: ["no-transcribe"],
            requiresApp: true,
            // Saving mixes both sources and runs the silence detector over the whole capture.
            timeout: 900
        ),
        CommandSpec(path: ["record", "pause"], summary: "Pause the current recording.", requiresApp: true),
        CommandSpec(path: ["record", "resume"], summary: "Resume the current recording.", requiresApp: true),
        CommandSpec(
            path: ["record", "discard"],
            summary: "Discard the current recording without saving it.",
            requiresApp: true
        ),
        CommandSpec(
            path: ["devices"],
            summary: "List microphones and displays available for recording.",
            requiresApp: true
        ),
    ]

    public static func spec(for path: [String]) -> CommandSpec? {
        commands.first { $0.path == path }
    }

    /// Longest match wins, so `summary show` never resolves to a bare `summary`.
    static func match(_ tokens: [String]) -> CommandSpec? {
        for length in stride(from: min(2, tokens.count), through: 1, by: -1) {
            if let spec = spec(for: Array(tokens.prefix(length))) { return spec }
        }
        return nil
    }

    public static func help(command: String? = nil) -> String {
        if let command, let spec = commands.first(where: { $0.name == command || $0.path.first == command }) {
            var lines = [spec.summary, "", spec.usage]
            if !spec.requiresApp { lines += ["", "Works while Stillnote is closed (reads the library directly)."] }
            return lines.joined(separator: "\n")
        }
        var lines = [
            "stillnote — read and correct your Stillnote meetings, and drive recording.",
            "",
            "Usage: stillnote <command> [options]",
            "",
            "Commands:",
        ]
        let width = commands.map(\.name.count).max() ?? 0
        for spec in commands {
            let name = spec.name.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("  \(name)  \(spec.summary)")
        }
        lines += [
            "",
            "Every command accepts --json. Commands that change data or record need the app running.",
            "Dates accept YYYY-MM-DD or YYYY-MM.",
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    public static func parse(
        _ argv: [String], standardInput: @autoclosure () -> String? = nil
    ) throws -> CLIInvocation {
        guard let first = argv.first else { throw CLIError.usage(help()) }
        guard let spec = match(argv) else {
            throw CLIError.usage("Unknown command '\(first)'. Run 'stillnote help'.")
        }
        let tokens = Array(argv.dropFirst(spec.path.count))

        var positionals: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        let valueOptions = Set(spec.valueOptions + globalValues)
        let booleanOptions = Set(spec.booleanOptions + globalBooleans)

        var index = 0
        var literal = false
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if literal || !token.hasPrefix("--") {
                positionals.append(token)
                continue
            }
            if token == "--" {
                literal = true
                continue
            }
            let body = String(token.dropFirst(2))
            let name: String
            var inline: String?
            if let separator = body.firstIndex(of: "=") {
                name = String(body[body.startIndex..<separator])
                inline = String(body[body.index(after: separator)...])
            } else {
                name = body
            }
            if valueOptions.contains(name) {
                if let inline {
                    values[name] = inline
                } else {
                    guard index < tokens.count else { throw CLIError.usage("--\(name) needs a value.") }
                    values[name] = tokens[index]
                    index += 1
                }
            } else if booleanOptions.contains(name) {
                guard inline == nil else { throw CLIError.usage("--\(name) does not take a value.") }
                flags.insert(name)
            } else {
                throw CLIError.usage("Unknown option '--\(name)' for '\(spec.name)'.\n\n\(spec.usage)")
            }
        }

        let wantsJSON = flags.contains("json")
        let wantsHelp = flags.contains("help")
        flags.remove("json")
        flags.remove("help")
        var timeout = spec.timeout
        if let raw = values.removeValue(forKey: "timeout") {
            guard let parsed = Double(raw), parsed > 0 else {
                throw CLIError.usage("--timeout needs a positive number of seconds.")
            }
            timeout = parsed
        }

        if wantsHelp {
            return CLIInvocation(
                spec: CommandCatalog.spec(for: ["help"])!,
                request: CLIRequest(command: ["help"], positionals: [spec.name]),
                wantsJSON: wantsJSON, timeout: timeout
            )
        }

        guard positionals.count >= spec.requiredPositionals else {
            throw CLIError.usage("'\(spec.name)' needs \(spec.requiredPositionals) argument(s).\n\n\(spec.usage)")
        }
        guard positionals.count <= spec.positionals.count else {
            throw CLIError.usage("'\(spec.name)' takes at most \(spec.positionals.count) argument(s).\n\n\(spec.usage)")
        }

        // Only the commands that say they read a body pay the cost of draining stdin.
        let readsStandardInput = flags.contains("stdin") || flags.contains("json-stdin")
        return CLIInvocation(
            spec: spec,
            request: CLIRequest(
                command: spec.path, positionals: positionals, values: values, flags: flags,
                standardInput: readsStandardInput ? standardInput() : nil
            ),
            wantsJSON: wantsJSON,
            timeout: timeout
        )
    }
}
