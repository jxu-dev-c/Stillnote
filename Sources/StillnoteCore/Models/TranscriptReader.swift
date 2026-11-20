import Foundation

/// How every meeting's transcript page is presented. One app-wide preference, chosen in
/// Settings → Transcribe.
public enum TranscriptDisplayMode: String, Codable, CaseIterable, Sendable {
    case lyrics
    case reader

    /// The `UserDefaults` key holding the preference.
    public static let defaultsKey = "stillnote.transcriptDisplayMode"

    public var label: String {
        switch self {
        case .lyrics: "Lyrics"
        case .reader: "Reader"
        }
    }

    public var detail: String {
        switch self {
        case .lyrics: "One line at a time, following playback."
        case .reader: "The full transcript as a document, grouped by speaker."
        }
    }
}

/// Consecutive transcript segments spoken by the same speaker, grouped for reader mode.
public struct TranscriptSpeakerGroup: Equatable, Identifiable, Sendable {
    public let id: String
    public let speaker: String
    public let startIndex: Int
    public let segments: [Segment]

    public init(id: String, speaker: String, startIndex: Int, segments: [Segment]) {
        self.id = id
        self.speaker = speaker
        self.startIndex = startIndex
        self.segments = segments
    }

    public var start: Double { segments.first?.start ?? 0 }
    public var end: Double { segments.last?.end ?? 0 }

    public func segmentIndex(at offset: Int) -> Int {
        startIndex + offset
    }
}

public enum TranscriptReader {
    /// Groups consecutive segments with the same `speaker` into speaker turns, preserving
    /// each segment's original index in the meeting transcript.
    public static func groups(for segments: [Segment]) -> [TranscriptSpeakerGroup] {
        var result: [TranscriptSpeakerGroup] = []
        for (index, segment) in segments.enumerated() {
            if let last = result.last, last.speaker == segment.speaker {
                result[result.count - 1] = TranscriptSpeakerGroup(
                    id: last.id,
                    speaker: last.speaker,
                    startIndex: last.startIndex,
                    segments: last.segments + [segment]
                )
            } else {
                result.append(
                    TranscriptSpeakerGroup(
                        id: segment.id,
                        speaker: segment.speaker,
                        startIndex: index,
                        segments: [segment]
                    )
                )
            }
        }
        return result
    }

    /// The segment ID of the active search match, if any. Prefers `focus` when it is one of
    /// `matches`; otherwise falls back to the first valid match index.
    public static func activeSearchMatchSegmentID(
        in segments: [Segment], matches: [Int], focus: Int
    ) -> String? {
        guard !matches.isEmpty else { return nil }
        if matches.contains(focus), segments.indices.contains(focus) {
            return segments[focus].id
        }
        guard let first = matches.first(where: { segments.indices.contains($0) }) else {
            return nil
        }
        return segments[first].id
    }

    /// All segment IDs that match the current transcript search.
    public static func matchingSegmentIDs(in segments: [Segment], matches: [Int]) -> Set<String> {
        Set(matches.compactMap { segments.indices.contains($0) ? segments[$0].id : nil })
    }

    /// Plain-text formatted transcript suitable for copying or exporting.
    public static func formattedText(for meeting: Meeting) -> String {
        meeting.segments.map {
            "[\(Formatting.timestamp($0.start))] \(meeting.speakerName($0.speaker)): \($0.text)"
        }.joined(separator: "\n\n")
    }
}
