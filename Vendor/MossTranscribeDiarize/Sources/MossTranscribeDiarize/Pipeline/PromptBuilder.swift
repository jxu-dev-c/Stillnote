import Foundation

/// Prompt helpers matching Python default + hotword usage.
public enum PromptBuilder {
    /// Build a prompt, optionally appending hotwords.
    public static func make(
        base: String = MossDefaults.prompt,
        hotwords: [String] = []
    ) -> String {
        let cleaned = hotwords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return base }
        let joined = cleaned.joined(separator: ", ")
        if base.contains("热词") || base.lowercased().contains("hotword") {
            return "\(base) \(joined)"
        }
        return "\(base)\n热词提示：\(joined)"
    }
}
