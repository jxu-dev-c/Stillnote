import Foundation
import Testing

@testable import StillnoteCore

private func transcript(_ lines: [(String, String)], summary: Bool = true) -> Meeting {
    var meeting = Meeting(
        id: "m1", title: "Meeting", audioName: "a.wav", language: "en", speakerCount: 2, duration: 600
    )
    meeting.speakers = ["speaker_1": "Jackson", "speaker_2": "Priya"]
    meeting.segments = lines.enumerated().map { index, line in
        Segment(
            id: "s\(index)", start: Double(index) * 10, end: Double(index) * 10 + 9,
            speaker: line.0, text: line.1
        )
    }
    meeting.status = summary ? .complete : .transcribed
    meeting.progress = 100
    if summary {
        meeting.summary = MeetingSummary(
            overview: "About ANE", keyPoints: [], decisions: [], actionItems: [], provider: "codex",
            model: "gpt-5-codex", generatedAt: Meeting.now()
        )
    }
    return meeting
}

@Suite struct TranscriptReplaceTests {
    @Test func replacesEveryOccurrenceAndCountsBoth() throws {
        var meeting = transcript([
            ("speaker_1", "The ANE build broke. ANE again."),
            ("speaker_2", "Not ANE this time."),
            ("speaker_1", "Unrelated line."),
        ])
        let outcome = try TranscriptEdit.replace(
            in: &meeting, options: ReplaceOptions(find: "ANE", replacement: "AEM")
        )
        #expect(outcome.matches == 3)
        #expect(outcome.segments == 2)
        #expect(meeting.segments[0].text == "The AEM build broke. AEM again.")
        #expect(meeting.segments[1].text == "Not AEM this time.")
        #expect(meeting.segments[2].text == "Unrelated line.")
    }

    /// The summary quoted the old text, so it cannot survive the correction.
    @Test func correctionInvalidatesTheSummary() throws {
        var meeting = transcript([("speaker_1", "ANE")])
        #expect(meeting.summary != nil)
        try TranscriptEdit.replace(in: &meeting, options: ReplaceOptions(find: "ANE", replacement: "AEM"))
        #expect(meeting.summary == nil)
        #expect(meeting.status == .transcribed)
        #expect(meeting.stage == "Transcript ready")
        #expect(meeting.progress == 100)
        #expect(meeting.error == nil)
    }

    @Test func noMatchChangesNothingAtAll() throws {
        var meeting = transcript([("speaker_1", "Nothing to see")])
        let before = meeting
        let outcome = try TranscriptEdit.replace(
            in: &meeting, options: ReplaceOptions(find: "ANE", replacement: "AEM")
        )
        #expect(outcome.isEmpty)
        #expect(meeting == before)
        #expect(meeting.summary != nil)
    }

    @Test func previewReportsWithoutWriting() throws {
        let meeting = transcript([("speaker_1", "ANE and ANE")])
        let outcome = try TranscriptEdit.preview(
            meeting, options: ReplaceOptions(find: "ANE", replacement: "AEM")
        )
        #expect(outcome.matches == 2)
        #expect(outcome.segments == 1)
        #expect(meeting.segments[0].text == "ANE and ANE")
        #expect(meeting.summary != nil)
    }

    @Test func caseSensitiveByDefault() throws {
        var meeting = transcript([("speaker_1", "ane and ANE")])
        #expect(try TranscriptEdit.replace(
            in: &meeting, options: ReplaceOptions(find: "ANE", replacement: "AEM")
        ).matches == 1)
        #expect(meeting.segments[0].text == "ane and AEM")
    }

    @Test func ignoreCaseMatchesEitherSpelling() throws {
        var meeting = transcript([("speaker_1", "ane and ANE")])
        #expect(try TranscriptEdit.replace(
            in: &meeting, options: ReplaceOptions(find: "ane", replacement: "AEM", ignoreCase: true)
        ).matches == 2)
        #expect(meeting.segments[0].text == "AEM and AEM")
    }

    @Test func wholeWordLeavesLongerWordsAlone() throws {
        var meeting = transcript([("speaker_1", "ANE, ANEs, and PLANE")])
        #expect(try TranscriptEdit.replace(
            in: &meeting, options: ReplaceOptions(find: "ANE", replacement: "AEM", wholeWord: true)
        ).matches == 1)
        #expect(meeting.segments[0].text == "AEM, ANEs, and PLANE")
    }

    /// Without --regex, punctuation in the search text is text, and `$1` in the replacement is
    /// literal rather than a capture reference.
    @Test func literalModeEscapesBothSides() throws {
        var meeting = transcript([("speaker_1", "costs $1.50 (approx.) today")])
        try TranscriptEdit.replace(
            in: &meeting, options: ReplaceOptions(find: "(approx.)", replacement: "about $1")
        )
        #expect(meeting.segments[0].text == "costs $1.50 about $1 today")
    }

    @Test func regexModeSupportsCapturesAndBoundaries() throws {
        var meeting = transcript([("speaker_1", "ticket AB-123 and AB-9")])
        try TranscriptEdit.replace(
            in: &meeting,
            options: ReplaceOptions(find: #"AB-(\d+)"#, replacement: "JIRA-$1", regex: true)
        )
        #expect(meeting.segments[0].text == "ticket JIRA-123 and JIRA-9")
    }

    @Test func wholeWordGroupsAnAlternationSoItCannotEscape() throws {
        var meeting = transcript([("speaker_1", "ANE or AEM or PLANE")])
        #expect(try TranscriptEdit.replace(
            in: &meeting,
            options: ReplaceOptions(find: "ANE|AEM", replacement: "X", regex: true, wholeWord: true)
        ).matches == 2)
        #expect(meeting.segments[0].text == "X or X or PLANE")
    }

    @Test func invalidPatternsAndEmptySearchesAreUsageErrors() {
        var meeting = transcript([("speaker_1", "text")])
        #expect(throws: CLIError.self) {
            try TranscriptEdit.replace(
                in: &meeting, options: ReplaceOptions(find: "[unclosed", replacement: "x", regex: true)
            )
        }
        #expect(throws: CLIError.self) {
            try TranscriptEdit.replace(in: &meeting, options: ReplaceOptions(find: "", replacement: "x"))
        }
    }

    /// A rewritten transcript still has to satisfy the bounds the store expects, which
    /// `Store.update` does not check on its own.
    @Test func rewrittenSegmentsStayValid() throws {
        var meeting = transcript([("speaker_1", "ANE"), ("speaker_2", "ANE")])
        try TranscriptEdit.replace(in: &meeting, options: ReplaceOptions(find: "ANE", replacement: "AEM"))
        let validated = try Validation.segments(meeting.segments, duration: meeting.duration)
        #expect(validated.count == 2)
        #expect(validated.map(\.text) == ["AEM", "AEM"])
    }

    @Test func refusesAReplacementThatWouldOverflowASegment() {
        var meeting = transcript([("speaker_1", "ANE")])
        let huge = String(repeating: "x", count: Validation.maxSegmentTextLength + 1)
        #expect(throws: CLIError.self) {
            try TranscriptEdit.replace(in: &meeting, options: ReplaceOptions(find: "ANE", replacement: huge))
        }
    }

    /// `finish` is the policy the window has always applied; the CLI shares it so a correction
    /// made in the terminal leaves the meeting in the same shape.
    @Test func finishBackfillsSpeakersAndResetsAnEmptyTranscript() {
        var meeting = transcript([("speaker_3", "who is this")])
        TranscriptEdit.finish(&meeting)
        #expect(meeting.speakers["speaker_3"] == "speaker_3")

        var empty = transcript([])
        TranscriptEdit.finish(&empty)
        #expect(empty.status == .ready)
        #expect(empty.progress == 0)
        #expect(empty.stage == "Ready to transcribe")
    }
}
