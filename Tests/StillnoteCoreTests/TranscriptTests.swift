import Foundation
import Testing

@testable import StillnoteCore

@Suite struct MossParserTests {
    @Test func assignsStableSpeakerIDsAndDisplayNames() throws {
        let text = "[0.00][S01]Hello there[1.20][1.20][S02]Hi back[2.50][2.50][S01]Again[3.00]"
        let result = try MossParser.parse(text, duration: 10, language: "en")
        #expect(result.segments.count == 3)
        #expect(result.segments.map(\.speaker) == ["speaker_1", "speaker_2", "speaker_1"])
        #expect(result.segments.map(\.id) == ["segment_1", "segment_2", "segment_3"])
        #expect(result.speakers == ["speaker_1": "Speaker 1", "speaker_2": "Speaker 2"])
        #expect(result.segments[0].text == "Hello there")
        #expect(result.language == "en")
    }

    /// Timestamps beyond the recording are clamped rather than trusted.
    @Test func clampsTimestampsToTheRecording() throws {
        let result = try MossParser.parse("[0.00][S01]Late[99.00]", duration: 5, language: "auto")
        #expect(result.segments[0].end == 5)
    }

    @Test func dropsEmptyUtterances() throws {
        let result = try MossParser.parse(
            "[0.00][S01]   [1.00][1.00][S01]real[2.00]", duration: 5, language: "auto"
        )
        #expect(result.segments.count == 1)
        #expect(result.segments[0].text == "real")
    }

    /// Output that does not fully match the transcript grammar is a truncated
    /// generation, not a partial transcript worth saving.
    @Test func rejectsIncompleteOutput() {
        #expect(throws: SpeechError.self) {
            try MossParser.parse("[0.00][S01]Only a start", duration: 5, language: "auto")
        }
        #expect(throws: SpeechError.self) {
            try MossParser.parse("[0.00][S01]ok[1.00] trailing junk", duration: 5, language: "auto")
        }
    }

    /// Real MOSS output: a leading space after the speaker tag, back-to-back cues, and
    /// a sentence containing punctuation the timestamp pattern must not match.
    @Test func parsesRealModelOutput() throws {
        let text = "[1.96][S01] Okay.[2.52][18.42][S01] Okay, now it comes back.[20.12]"
            + "[61.88][S01] You can still hear the muted Teams voice, so that's something to work on.[67.31]"
        let result = try MossParser.parse(text, duration: 81, language: "auto")
        #expect(result.segments.count == 3)
        #expect(result.segments[0].text == "Okay.")
        #expect(result.segments[1].start == 18.42)
        #expect(result.segments[2].end == 67.31)
        #expect(result.speakers == ["speaker_1": "Speaker 1"])
    }

    @Test func acceptsEmptyOutput() throws {
        let result = try MossParser.parse("   ", duration: 5, language: "auto")
        #expect(result.segments.isEmpty)
        #expect(result.speakers.isEmpty)
    }
}

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
