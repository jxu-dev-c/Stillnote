import Foundation

/// Subtitle timing/text normalization ported from Python `subtitle/postprocess.py`.
public enum SubtitlePostprocess {
    public static let defaultMinDuration: Double = 1.0
    public static let defaultMaxDuration: Double = 6.0
    public static let defaultMaxChars: Int = 24
    public static let defaultMergeGap: Double = 0.3

    private static let punctuation = CharacterSet(charactersIn: "。！？!?；;，,、 ")

    public static func subtitleSegments(
        from transcript: String,
        postprocess: Bool = true,
        minDuration: Double = defaultMinDuration,
        maxDuration: Double = defaultMaxDuration,
        maxChars: Int = defaultMaxChars,
        mergeGap: Double = defaultMergeGap
    ) -> [SubtitleSegment] {
        subtitleSegments(
            from: parseTranscript(transcript),
            postprocess: postprocess,
            minDuration: minDuration,
            maxDuration: maxDuration,
            maxChars: maxChars,
            mergeGap: mergeGap
        )
    }

    public static func subtitleSegments(
        from segments: [TranscriptSegment],
        postprocess: Bool = true,
        minDuration: Double = defaultMinDuration,
        maxDuration: Double = defaultMaxDuration,
        maxChars: Int = defaultMaxChars,
        mergeGap: Double = defaultMergeGap
    ) -> [SubtitleSegment] {
        let cues = segments.enumerated().map { index, segment in
            SubtitleSegment(
                id: String(format: "seg_%04d", index + 1),
                start: segment.start,
                end: segment.end,
                speaker: segment.speaker,
                text: segment.text
            )
        }
        guard postprocess else { return cues }
        return normalize(
            cues,
            minDuration: minDuration,
            maxDuration: maxDuration,
            maxChars: maxChars,
            mergeGap: mergeGap,
            regenerateIDs: true
        )
    }

    public static func normalize(
        _ segments: [SubtitleSegment],
        minDuration: Double = defaultMinDuration,
        maxDuration: Double = defaultMaxDuration,
        maxChars: Int = defaultMaxChars,
        mergeGap: Double = defaultMergeGap,
        regenerateIDs: Bool = false
    ) -> [SubtitleSegment] {
        var prepared = prepare(segments)
        prepared = fixOverlaps(prepared, minDuration: minDuration)
        prepared = mergeAdjacent(prepared, mergeGap: mergeGap, maxChars: maxChars)
        prepared = splitLong(prepared, minDuration: minDuration, maxDuration: maxDuration, maxChars: maxChars)
        prepared = fixOverlaps(prepared, minDuration: minDuration)
        if regenerateIDs {
            for index in prepared.indices {
                prepared[index].id = String(format: "seg_%04d", index + 1)
            }
        }
        return prepared
    }

    // MARK: - Steps

    private static func prepare(_ segments: [SubtitleSegment]) -> [SubtitleSegment] {
        var prepared: [SubtitleSegment] = []
        for (index, segment) in segments.enumerated() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = max(0, segment.start)
            let end = max(start, segment.end)
            prepared.append(
                SubtitleSegment(
                    id: segment.id.isEmpty ? String(format: "seg_%04d", index + 1) : segment.id,
                    start: start,
                    end: end,
                    speaker: segment.speaker.isEmpty ? "S00" : segment.speaker,
                    text: text
                )
            )
        }
        return prepared.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.end < rhs.end }
            return lhs.start < rhs.start
        }
    }

    private static func fixOverlaps(_ segments: [SubtitleSegment], minDuration: Double) -> [SubtitleSegment] {
        var cursor = 0.0
        var fixed: [SubtitleSegment] = []
        for segment in segments {
            let start = max(segment.start, cursor)
            let end = max(segment.end, start + minDuration)
            fixed.append(
                SubtitleSegment(
                    id: segment.id,
                    start: start,
                    end: end,
                    speaker: segment.speaker,
                    text: segment.text
                )
            )
            cursor = end
        }
        return fixed
    }

    private static func mergeAdjacent(
        _ segments: [SubtitleSegment],
        mergeGap: Double,
        maxChars: Int
    ) -> [SubtitleSegment] {
        guard var merged = segments.first.map({ [$0] }) else { return [] }
        for segment in segments.dropFirst() {
            let previous = merged[merged.count - 1]
            let gap = segment.start - previous.end
            let combined = joinText(previous.text, segment.text)
            let canMerge =
                previous.speaker == segment.speaker
                && gap >= 0
                && gap <= mergeGap
                && combined.count <= maxChars * 2
            if canMerge {
                merged[merged.count - 1] = SubtitleSegment(
                    id: previous.id,
                    start: previous.start,
                    end: max(previous.end, segment.end),
                    speaker: previous.speaker,
                    text: combined
                )
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    private static func splitLong(
        _ segments: [SubtitleSegment],
        minDuration: Double,
        maxDuration: Double,
        maxChars: Int
    ) -> [SubtitleSegment] {
        var output: [SubtitleSegment] = []
        for segment in segments {
            let duration = segment.end - segment.start
            if duration <= maxDuration && segment.text.count <= maxChars {
                output.append(segment)
                continue
            }
            let chunks = splitText(segment.text, maxChars: maxChars)
            if chunks.count <= 1 {
                output.append(segment)
                continue
            }
            let totalChars = chunks.map { max($0.count, 1) }.reduce(0, +)
            var cursor = segment.start
            for (index, chunk) in chunks.enumerated() {
                let end: Double
                if index == chunks.count - 1 {
                    end = segment.end
                } else {
                    let ratio = Double(max(chunk.count, 1)) / Double(totalChars)
                    var candidate = cursor + max(minDuration, duration * ratio)
                    candidate = min(candidate, segment.end - minDuration * Double(chunks.count - index - 1))
                    end = candidate
                }
                output.append(
                    SubtitleSegment(
                        id: "\(segment.id)_\(index + 1)",
                        start: cursor,
                        end: max(end, cursor + minDuration),
                        speaker: segment.speaker,
                        text: chunk
                    )
                )
                cursor = output[output.count - 1].end
            }
        }
        return output
    }

    private static func splitText(_ text: String, maxChars: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars { return [trimmed] }

        var chunks: [String] = []
        var current = ""
        for character in trimmed {
            current.append(character)
            let shouldCut =
                current.count >= maxChars
                || (character.unicodeScalars.allSatisfy { punctuation.contains($0) }
                    && current.count >= maxChars / 2)
            if shouldCut {
                let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { chunks.append(piece) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }

        var compact: [String] = []
        for chunk in chunks where !chunk.isEmpty {
            if let last = compact.last, last.count + chunk.count <= maxChars {
                compact[compact.count - 1] = joinText(last, chunk)
            } else {
                compact.append(chunk)
            }
        }
        return compact
    }

    private static func joinText(_ left: String, _ right: String) -> String {
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        if left.last?.isASCII == true, right.first?.isASCII == true {
            return "\(left) \(right)"
        }
        return left + right
    }
}
