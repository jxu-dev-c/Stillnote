import Foundation

public enum GenerationProgress: Sendable {
    case encoding(Int, Int)
    case prefill(Int, Int)
    case decoded(String)
}

/// Pure guards shared by native generation and regression tests.
public enum GenerationPolicy {
    private static let repetitionTextLimit = 16_384
    private static let repetitionRowLimit = 96
    private static let repetitionBlockLimit = 32
    private static let timestampedRow = try! NSRegularExpression(
        pattern: #"\[[0-9.]+\]\[(S\d+)\](.*?)\[[0-9.]+\]"#,
        options: [.dotMatchesLineSeparators]
    )

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

    public static func checkRepetition(_ tokens: [Int], decodedText: String? = nil) throws {
        if tokens.count >= 384,
           tokens.suffix(128).elementsEqual(tokens.dropLast(128).suffix(128)),
           tokens.suffix(128).elementsEqual(tokens.dropLast(256).suffix(128)) {
            throw MossError.generationFailed("MOSS began repeating its output. Your recording is saved; retry transcription.")
        }
        if let decodedText, hasTimestampInsensitiveLoop(decodedText) {
            throw MossError.generationFailed("MOSS began repeating its output. Your recording is saved; change transcription settings before retrying.")
        }
    }

    /// Timestamp values legitimately advance while a decoder is stuck repeating the
    /// same transcription rows. Compare complete row payloads so those values cannot
    /// hide a loop, while requiring a substantial repeated block to avoid natural
    /// short acknowledgements.
    private static func hasTimestampInsensitiveLoop(_ text: String) -> Bool {
        // Only a suffix can be part of the current loop. Keeping this bounded also makes the
        // periodic guard independent of recording length.
        let tail = String(text.suffix(repetitionTextLimit))
        let range = NSRange(tail.startIndex..., in: tail)
        let rows = timestampedRow.matches(in: tail, range: range).suffix(repetitionRowLimit).compactMap { match -> String? in
            func group(_ index: Int) -> String {
                Range(match.range(at: index), in: tail).map { String(tail[$0]) } ?? ""
            }
            let payload = group(2).trimmingCharacters(in: .whitespacesAndNewlines)
            return payload.isEmpty ? nil : "\(group(1))\u{1F}\(payload)"
        }
        guard rows.count >= 3 else { return false }
        for blockSize in 1...min(repetitionBlockLimit, rows.count / 3) {
            let block = Array(rows.suffix(blockSize))
            guard block.joined().count >= 128 else { continue }
            let preceding = rows.dropLast(blockSize)
            guard block.elementsEqual(preceding.suffix(blockSize)) else { continue }
            guard block.elementsEqual(preceding.dropLast(blockSize).suffix(blockSize)) else { continue }
            return true
        }
        return false
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
