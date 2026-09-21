import Foundation

public enum SummaryProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claudeCode = "claude-code"

    public var label: String { self == .codex ? "Codex" : "Claude Code" }
    public var command: String { self == .codex ? "codex" : "claude" }
    public var environmentOverride: String { self == .codex ? "STILLNOTE_CODEX_BIN" : "STILLNOTE_CLAUDE_BIN" }
    public var defaultModel: String { self == .codex ? "gpt-5.6-luna" : "claude-sonnet-5" }
}

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable {
    case low, medium, high
    public var label: String { rawValue.capitalized }
}

public enum TranscriptionMode: String, Codable, CaseIterable, Sendable {
    case quality, balanced
    case lowMemory = "low-memory"
    public var label: String { switch self { case .quality: "Quality"; case .balanced: "Balanced"; case .lowMemory: "Low Memory" } }
    public var detail: String { switch self {
    case .quality: "Prioritizes transcription accuracy and speaker consistency. Uses more memory."
    case .balanced: "Uses less memory while keeping the whole meeting in context. Recognition may differ."
    case .lowMemory: "Uses the least memory. Accuracy and speaker labels may differ."
    } }
    public var prefillStepSize: Int { switch self { case .quality: 512; case .balanced: 128; case .lowMemory: 64 } }
}

public struct TranscriptionSettings: Codable, Hashable, Sendable {
    public var model: String
    public var language: String
    public var speakerCount: Int?
    public var hotWords: [String]
    public var mode: TranscriptionMode

    enum CodingKeys: String, CodingKey {
        case model, language, mode
        case speakerCount = "speaker_count"
        case hotWords = "hot_words"
    }

    public init(model: String = SpeechCatalog.defaultModel, language: String = "auto", speakerCount: Int? = nil, hotWords: [String] = [], mode: TranscriptionMode = .quality) {
        self.mode = mode
        self.model = model
        self.language = language
        self.speakerCount = speakerCount
        self.hotWords = Self.normalizeHotWords(hotWords)
    }

    public static func normalizeHotWords(_ words: [String]) -> [String] {
        var seen = Set<String>()
        return words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            model: try values.decode(String.self, forKey: .model),
            language: try values.decode(String.self, forKey: .language),
            speakerCount: try values.decodeIfPresent(Int.self, forKey: .speakerCount),
            hotWords: try values.decodeIfPresent([String].self, forKey: .hotWords) ?? [],
            mode: (try values.decodeIfPresent(String.self, forKey: .mode)).flatMap(TranscriptionMode.init(rawValue:)) ?? .quality
        )
    }
}

public struct SummarySettings: Codable, Hashable, Sendable {
    public var provider: SummaryProvider
    public var model: String
    public var reasoningEffort: ReasoningEffort
    public var bypassPermissions: Bool
    public var inheritShellEnvironment: Bool
    public var shellPath: String
    public var agentPrompt: String

    public var resolvedAgentPrompt: String {
        agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Summarizer.defaultAgentPrompt : agentPrompt
    }

    enum CodingKeys: String, CodingKey {
        case provider, model
        case reasoningEffort = "reasoning_effort"
        case agentPrompt = "agent_prompt"
        case inheritShellEnvironment = "inherit_shell_environment"
        case shellPath = "shell_path"
        case bypassPermissions = "bypass_permissions"
    }

    public init(
        provider: SummaryProvider = .codex, model: String? = nil, reasoningEffort: ReasoningEffort = .high,
        agentPrompt: String = Summarizer.defaultAgentPrompt,
        inheritShellEnvironment: Bool = true, shellPath: String = "", bypassPermissions: Bool = true
    ) {
        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.reasoningEffort = reasoningEffort
        self.agentPrompt = agentPrompt
        self.inheritShellEnvironment = inheritShellEnvironment
        self.shellPath = shellPath
        self.bypassPermissions = bypassPermissions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decode(SummaryProvider.self, forKey: .provider)
        model = try values.decode(String.self, forKey: .model)
        reasoningEffort = try values.decode(ReasoningEffort.self, forKey: .reasoningEffort)
        bypassPermissions = try values.decodeIfPresent(Bool.self, forKey: .bypassPermissions) ?? true
        inheritShellEnvironment = try values.decodeIfPresent(Bool.self, forKey: .inheritShellEnvironment) ?? true
        shellPath = try values.decodeIfPresent(String.self, forKey: .shellPath) ?? ""
        agentPrompt = try values.decodeIfPresent(String.self, forKey: .agentPrompt) ?? Summarizer.defaultAgentPrompt
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var transcription: TranscriptionSettings
    public var summary: SummarySettings

    public init(transcription: TranscriptionSettings = .init(), summary: SummarySettings = .init()) {
        self.transcription = transcription
        self.summary = summary
    }

    /// Speech models retired before MOSS became the only supported engine.
    static let retiredSpeechModels: Set<String> = [
        "tiny", "base", "small", "tiny.en", "base.en", "small.en", "vibevoice-1.5b", "vibevoice-7b",
    ]

    /// Reads settings leniently so a record written by the Python app — including one
    /// holding retired providers and API credentials — loads and migrates in place.
    public static func migrating(from object: [String: Any]) -> (settings: AppSettings, changed: Bool) {
        var settings = AppSettings()
        var changed = false

        let transcription = object["transcription"] as? [String: Any] ?? [:]
        var model = transcription["model"] as? String ?? SpeechCatalog.defaultModel
        if retiredSpeechModels.contains(model) || SpeechCatalog.models[model] == nil {
            model = SpeechCatalog.defaultModel
            changed = true
        }
        settings.transcription = TranscriptionSettings(
            model: model,
            language: transcription["language"] as? String ?? "auto",
            speakerCount: transcription["speaker_count"] as? Int,
            hotWords: transcription["hot_words"] as? [String] ?? [],
            mode: (transcription["mode"] as? String).flatMap(TranscriptionMode.init(rawValue:)) ?? .quality
        )

        let summary = object["summary"] as? [String: Any] ?? [:]
        let rawProvider = summary["provider"] as? String ?? SummaryProvider.codex.rawValue
        let provider: SummaryProvider
        var resetModel = false
        if let known = SummaryProvider(rawValue: rawProvider) {
            provider = known
        } else {
            // Retired API providers migrate to the closest coding agent and lose their
            // saved model, endpoint, and credential fields.
            provider = rawProvider == "anthropic" ? .claudeCode : .codex
            resetModel = true
            changed = true
        }
        let storedModel = resetModel ? nil : (summary["model"] as? String)
        let storedEffort = resetModel ? nil : (summary["reasoning_effort"] as? String)
        settings.summary = SummarySettings(
            provider: provider,
            model: (storedModel?.isEmpty == false) ? storedModel : provider.defaultModel,
            reasoningEffort: storedEffort.flatMap(ReasoningEffort.init(rawValue:)) ?? .high,
            agentPrompt: summary["agent_prompt"] as? String ?? Summarizer.defaultAgentPrompt,
            inheritShellEnvironment: summary["inherit_shell_environment"] as? Bool ?? true,
            shellPath: summary["shell_path"] as? String ?? "",
            bypassPermissions: summary["bypass_permissions"] as? Bool ?? true
        )
        // Obsolete keys such as api_key and base_url are dropped by re-encoding.
        if summary["agent_prompt"] as? String == nil || (summary.keys.contains { !["provider", "model", "reasoning_effort", "agent_prompt", "inherit_shell_environment", "shell_path", "bypass_permissions"].contains($0) }) {
            changed = true
        }
        if transcription["model"] as? String != settings.transcription.model { changed = true }
        return (settings, changed)
    }
}
