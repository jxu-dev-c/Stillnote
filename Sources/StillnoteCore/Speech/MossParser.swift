import Foundation

public struct TranscriptionResult: Sendable {
    public let duration: Double
    public let language: String
    public let speakers: [String: String]
    public let segments: [Segment]
}

/// Parses MOSS's `[start][S01]text[end]` output and turns its raw speaker tags into
/// the stable `speaker_n` ids and display names the rest of the app uses.
public enum MossParser {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\[([0-9.]+)\]\[(S\d+)\](.*?)\[([0-9.]+)\]"#, options: [.dotMatchesLineSeparators]
    )

    struct Row {
        let start: Double
        let end: Double
        let speaker: String
        let text: String
    }

    static func rows(from text: String) throws -> [Row] {
        let full = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: full)
        let leftover = pattern.stringByReplacingMatches(in: text, range: full, withTemplate: "")
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           matches.isEmpty || !leftover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SpeechError.message("MOSS returned an incomplete transcript. Please retry transcription.")
        }
        return matches.compactMap { match in
            func group(_ index: Int) -> String {
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            guard let start = Double(group(1)), let end = Double(group(4)) else { return nil }
            return Row(start: start, end: end, speaker: group(2), text: group(3))
        }
    }

    public static func parse(_ text: String, duration: Double, language: String) throws -> TranscriptionResult {
        var labels: [String: String] = [:]
        var order: [String] = []
        var segments: [Segment] = []
        for row in try rows(from: text) {
            guard row.start.isFinite, row.end.isFinite, row.end >= row.start else {
                throw SpeechError.message("The model returned invalid timestamps. Please retry transcription.")
            }
            let content = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { continue }
            if labels[row.speaker] == nil {
                let label = row.speaker == "unknown" ? "speaker_unknown" : "speaker_\(labels.count + 1)"
                labels[row.speaker] = label
                order.append(label)
            }
            segments.append(
                Segment(
                    id: "segment_\(segments.count + 1)",
                    start: (max(0, min(row.start, duration)) * 1000).rounded() / 1000,
                    end: (max(0, min(row.end, duration)) * 1000).rounded() / 1000,
                    speaker: labels[row.speaker]!,
                    text: content
                )
            )
        }
        var speakers: [String: String] = [:]
        for (index, label) in order.enumerated() {
            speakers[label] = label == "speaker_unknown" ? "Unknown speaker" : "Speaker \(index + 1)"
        }
        return TranscriptionResult(
            duration: (duration * 1000).rounded() / 1000,
            language: language.isEmpty ? "auto" : language,
            speakers: speakers,
            segments: segments
        )
    }
}
