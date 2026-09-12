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

public struct TranscriptionSettings: Codable, Hashable, Sendable {
    public var model: String
    public var language: String
    public var speakerCount: Int?

    enum CodingKeys: String, CodingKey {
        case model, language
        case speakerCount = "speaker_count"
    }

    public init(model: String = SpeechCatalog.defaultModel, language: String = "auto", speakerCount: Int? = nil) {
        self.model = model
        self.language = language
        self.speakerCount = speakerCount
    }
}

public struct SummarySettings: Codable, Hashable, Sendable {
    public var provider: SummaryProvider
    public var model: String
    public var reasoningEffort: ReasoningEffort

    enum CodingKeys: String, CodingKey {
        case provider, model
        case reasoningEffort = "reasoning_effort"
    }

    public init(
        provider: SummaryProvider = .codex, model: String? = nil, reasoningEffort: ReasoningEffort = .high
    ) {
        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.reasoningEffort = reasoningEffort
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
            speakerCount: transcription["speaker_count"] as? Int
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
            reasoningEffort: storedEffort.flatMap(ReasoningEffort.init(rawValue:)) ?? .high
        )
        // Obsolete keys such as api_key and base_url are dropped by re-encoding.
        if object["summary"] == nil || (summary.keys.contains { !["provider", "model", "reasoning_effort"].contains($0) }) {
            changed = true
        }
        if transcription["model"] as? String != settings.transcription.model { changed = true }
        return (settings, changed)
    }
}
