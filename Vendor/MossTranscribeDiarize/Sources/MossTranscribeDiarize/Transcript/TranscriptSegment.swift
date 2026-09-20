import Foundation

/// One diarized transcript segment: `[start][Sxx]text[end]`.
public struct TranscriptSegment: Sendable, Equatable, Identifiable, Codable, Hashable {
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String

    public var id: String {
        "\(speaker)-\(start)-\(end)-\(text.hashValue)"
    }

    public var duration: Double {
        max(0, end - start)
    }

    public init(start: Double, end: Double, speaker: String, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}
