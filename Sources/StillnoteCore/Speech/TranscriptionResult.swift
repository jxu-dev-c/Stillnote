import Foundation

public struct TranscriptionResult: Sendable {
    public let duration: Double
    public let language: String
    public let speakers: [String: String]
    public let segments: [Segment]

    public init(duration: Double, language: String, speakers: [String: String], segments: [Segment]) {
        self.duration = duration
        self.language = language
        self.speakers = speakers
        self.segments = segments
    }
}
