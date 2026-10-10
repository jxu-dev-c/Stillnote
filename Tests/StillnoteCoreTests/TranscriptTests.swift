import Foundation
import Testing

@testable import StillnoteCore

@Suite struct ValidationTests {
    @Test func normalizesAndRejectsContextLinks() throws {
        #expect(try Validation.contextLinkURL("example.com/docs") == "https://example.com/docs")
        #expect(throws: ValidationError.self) { try Validation.contextLinkURL("ftp://example.com") }
        #expect(throws: ValidationError.self) { try Validation.contextLinkURL("https://user:pw@example.com") }
        #expect(throws: ValidationError.self) {
            try Validation.contextLinkURL("https://a.test", existing: [ContextLink(url: "https://a.test")])
        }
    }

    @Test func sortsSegmentsAndEnforcesUniqueIDs() throws {
        let segments = [
            Segment(id: "b", start: 5, end: 6, speaker: "s", text: "second"),
            Segment(id: "a", start: 0, end: 1, speaker: "s", text: "first"),
        ]
        #expect(try Validation.segments(segments, duration: 10).map(\.id) == ["a", "b"])
        #expect(throws: ValidationError.self) {
            try Validation.segments(
                [Segment(id: "a", start: 0, end: 1, speaker: "s", text: ""),
                 Segment(id: "a", start: 1, end: 2, speaker: "s", text: "")],
                duration: 10
            )
        }
        // A segment must fit the recording, with a small tolerance for model rounding.
        #expect(throws: ValidationError.self) {
            try Validation.segments([Segment(id: "a", start: 0, end: 20, speaker: "s", text: "")], duration: 10)
        }
    }

    @Test func formatsDurationsAndTimestamps() {
        #expect(Formatting.duration(75) == "1:15")
        #expect(Formatting.duration(3725) == "1:02:05")
        #expect(Formatting.timestamp(3725.5) == "01:02:05")
        #expect(Formatting.timestamp(1.25, srt: true) == "00:00:01,250")
    }
}
