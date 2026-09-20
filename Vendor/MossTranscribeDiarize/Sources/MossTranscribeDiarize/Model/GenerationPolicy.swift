import Foundation

public enum GenerationProgress: Sendable {
    case encoding(Int, Int)
    case prefill(Int, Int)
    case decoded(String)
}

/// Pure guards shared by native generation and regression tests.
public enum GenerationPolicy {
    public static func tokenLimit(requested: Int, promptTokens: Int, contextSize: Int) throws -> Int {
        let available = contextSize - promptTokens - 1
        guard requested > 0, available >= 256 else {
            throw MossError.generationFailed("This recording exceeds the MOSS context limit. Import a shorter recording.")
        }
        return min(65536, requested, available)
    }

    public static func completedTokens(_ tokens: [Int], reachedEOS: Bool) throws -> [Int] {
        guard reachedEOS else {
            throw MossError.generationFailed("MOSS reached its output limit. No partial transcript was saved.")
        }
        return tokens
    }

    public static func checkRepetition(_ tokens: [Int]) throws {
        guard tokens.count >= 384 else { return }
        if tokens.suffix(128).elementsEqual(tokens.dropLast(128).suffix(128)),
           tokens.suffix(128).elementsEqual(tokens.dropLast(256).suffix(128)) {
            throw MossError.generationFailed("MOSS began repeating its output. Your recording is saved; retry transcription.")
        }
    }
}

/// Used synchronously by one generation callback. Never decode a single BPE token.
final class StreamingText: @unchecked Sendable {
    private var emitted = ""
    func append(_ text: String) -> String? {
        guard !text.contains("\u{FFFD}"), text.hasPrefix(emitted) else { return nil }
        let delta = String(text.dropFirst(emitted.count))
        emitted = text
        return delta.isEmpty ? nil : delta
    }
}
