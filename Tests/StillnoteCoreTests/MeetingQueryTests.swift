import Foundation
import Testing

@testable import StillnoteCore

private func meeting(
    _ id: String, _ title: String, _ createdAt: String, speakers: [String: String] = [:],
    lines: [String] = [], notes: String = "", summary: MeetingSummary? = nil,
    status: MeetingStatus = .transcribed
) -> Meeting {
    var meeting = Meeting(
        id: id, title: title, audioName: "a.wav", language: "en", speakerCount: nil, duration: 900
    )
    meeting.createdAt = createdAt
    meeting.updatedAt = createdAt
    meeting.speakers = speakers
    meeting.segments = lines.enumerated().map { index, text in
        Segment(
            id: "s\(index)", start: Double(index) * 10, end: Double(index) * 10 + 9,
            speaker: speakers.keys.sorted().first ?? "speaker_1", text: text
        )
    }
    meeting.notes = notes
    meeting.summary = summary
    meeting.status = status
    return meeting
}

private let library: [Meeting] = [
    meeting(
        "aa11", "Product launch planning", "2026-09-08T15:04:05.100+00:00",
        speakers: ["speaker_1": "Jackson", "speaker_2": "Priya"],
        lines: ["The decision is to ship the launch in Sept.", "Jackson will own it."],
        notes: "Follow up on the launch",
        summary: MeetingSummary(
            overview: "Decided the Sept launch ships.", keyPoints: ["Sept is firm"],
            decisions: ["Ship in Sept"], actionItems: [ActionItem(text: "Own the launch", owner: "Jackson")],
            provider: "codex", model: "gpt-5-codex", generatedAt: "2026-09-08T16:00:00.000+00:00"
        ), status: .complete
    ),
    meeting(
        "bb22", "Weekly sync", "2026-05-14T10:00:00.000+00:00",
        speakers: ["speaker_1": "Jackson"], lines: ["Throughput next week."]
    ),
    meeting(
        "bb33", "May retro", "2026-05-31T23:30:00.000+00:00",
        speakers: ["speaker_1": "Priya"], lines: ["Quiet month."]
    ),
    meeting("cc44", "Hiring debrief", "2026-08-02T11:15:00.000+00:00", speakers: ["speaker_1": "Dana"]),
]

@Suite struct MeetingQueryTests {
    // MARK: - Dates

    @Test func parsesDaysAndMonthsAsHalfOpenRanges() throws {
        let day = try MeetingQuery.range("2026-05-17")
        #expect(day.end.timeIntervalSince(day.start) == 86_400)
        let month = try MeetingQuery.range("2026-05")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        #expect(calendar.component(.month, from: month.start) == 5)
        #expect(calendar.component(.month, from: month.end) == 6)
        #expect(calendar.component(.day, from: month.end) == 1)
    }

    @Test func rejectsTextThatIsNotADate() {
        for bad in ["May", "2026", "2026-13", "2026-02-30", "2026-05-", "yesterday", "26-05-01"] {
            #expect(throws: CLIError.self, "'\(bad)' should not parse") { try MeetingQuery.range(bad) }
        }
    }

    /// "Back in May" becomes `--since 2026-05 --until 2026-05`, and the whole month is included:
    /// a meeting late on the 31st must not fall outside the range.
    @Test func aWholeMonthIncludesItsLastDay() throws {
        let filter = MeetingFilter(
            since: try MeetingQuery.range("2026-05").start, until: try MeetingQuery.range("2026-05").end
        )
        #expect(MeetingQuery.filter(library, filter).map(\.id) == ["bb33", "bb22"])
    }

    @Test func singleDayRangeIsInclusiveOfThatDay() throws {
        let day = try MeetingQuery.range("2026-05-14")
        #expect(MeetingQuery.filter(library, MeetingFilter(since: day.start, until: day.end)).map(\.id) == ["bb22"])
    }

    // MARK: - Filtering

    @Test func sortsNewestFirstAndAppliesTheLimitLast() {
        #expect(MeetingQuery.filter(library, MeetingFilter()).map(\.id) == ["aa11", "cc44", "bb33", "bb22"])
        #expect(MeetingQuery.filter(library, MeetingFilter(limit: 2)).map(\.id) == ["aa11", "cc44"])
    }

    @Test func filtersBySpeakerNameAndDiarizationID() {
        #expect(MeetingQuery.filter(library, MeetingFilter(speaker: "jackson")).map(\.id) == ["aa11", "bb22"])
        #expect(MeetingQuery.filter(library, MeetingFilter(speaker: "speaker_2")).map(\.id) == ["aa11"])
        #expect(MeetingQuery.filter(library, MeetingFilter(speaker: "nobody")).isEmpty)
    }

    @Test func filtersByStatus() {
        #expect(MeetingQuery.filter(library, MeetingFilter(status: .complete)).map(\.id) == ["aa11"])
    }

    /// The combined shape of "all my conversations with Jackson back in May".
    @Test func combinesSpeakerAndMonth() throws {
        let filter = MeetingFilter(
            since: try MeetingQuery.range("2026-05").start,
            until: try MeetingQuery.range("2026-05").end, speaker: "Jackson"
        )
        #expect(MeetingQuery.filter(library, filter).map(\.id) == ["bb22"])
    }

    // MARK: - Resolving a reference

    @Test func resolvesLatestExactPrefixAndTitle() throws {
        #expect(try MeetingQuery.resolve("latest", in: library).id == "aa11")
        #expect(try MeetingQuery.resolve("LATEST", in: library).id == "aa11")
        #expect(try MeetingQuery.resolve("cc44", in: library).id == "cc44")
        #expect(try MeetingQuery.resolve("aa", in: library).id == "aa11")
        #expect(try MeetingQuery.resolve("May retro", in: library).id == "bb33")
    }

    @Test func reportsAmbiguousAndMissingReferences() {
        #expect(throws: CLIError.self) { try MeetingQuery.resolve("bb", in: library) }
        #expect(throws: CLIError.self) { try MeetingQuery.resolve("zz", in: library) }
        #expect(throws: CLIError.self) { try MeetingQuery.resolve("  ", in: library) }
        #expect(throws: CLIError.self) { try MeetingQuery.resolve("latest", in: []) }
    }

    // MARK: - Search

    @Test func searchesEveryFieldByDefault() throws {
        let results = try MeetingQuery.search(library, query: "launch")
        #expect(results.count == 1)
        let fields = Set(results[0].hits.map(\.field))
        #expect(fields == [.title, .transcript, .summary, .notes])
        #expect(results[0].matches == results[0].hits.count)
    }

    @Test func scopesToTheRequestedFields() throws {
        let transcript = try MeetingQuery.search(library, query: "launch", fields: [.transcript])
        #expect(transcript[0].hits.allSatisfy { $0.field == .transcript })
        #expect(try MeetingQuery.search(library, query: "retro", fields: [.transcript]).isEmpty)
        #expect(try MeetingQuery.search(library, query: "retro", fields: [.title]).count == 1)
    }

    @Test func transcriptHitsCarryTheSpeakerAndTimestamp() throws {
        let results = try MeetingQuery.search(library, query: "decision", fields: [.transcript])
        #expect(results[0].hits[0].speaker == "Jackson")
        #expect(results[0].hits[0].start == 0)
    }

    @Test func searchIsCaseInsensitiveAndCountsRepeats() throws {
        var meeting = meeting("dd55", "Repeats", "2026-01-01T00:00:00.000+00:00")
        meeting.notes = "ANE ane AnE"
        #expect(try MeetingQuery.search([meeting], query: "ane")[0].matches == 3)
    }

    @Test func searchHonoursTheDateAndSpeakerFilters() throws {
        let filter = MeetingFilter(
            since: try MeetingQuery.range("2026-05").start, until: try MeetingQuery.range("2026-05").end
        )
        #expect(try MeetingQuery.search(library, query: "week", filter: filter).map(\.id) == ["bb22"])
        #expect(try MeetingQuery.search(library, query: "launch", filter: filter).isEmpty)
    }

    @Test func rejectsAnEmptyQueryOrUnknownField() {
        #expect(throws: CLIError.self) { try MeetingQuery.search(library, query: "   ") }
        #expect(throws: CLIError.self) { try MeetingQuery.fields("transcript,nope") }
        #expect(throws: CLIError.self) { try MeetingQuery.fields(",") }
        #expect(try! MeetingQuery.fields(nil) == Set(SearchField.allCases))
        #expect(try! MeetingQuery.fields("transcript, summary") == [.transcript, .summary])
    }

    @Test func snippetsWindowLongPassagesAroundTheMatch() {
        let filler = String(repeating: "word ", count: 60)
        let text = filler + "NEEDLE " + filler
        let snippet = MeetingQuery.snippet(text, around: "needle", context: 20)
        #expect(snippet.contains("NEEDLE"))
        #expect(snippet.hasPrefix("…"))
        #expect(snippet.hasSuffix("…"))
        #expect(snippet.count < text.count)
        // A short passage is returned whole, with newlines flattened so one hit is one line.
        #expect(MeetingQuery.snippet("a\nb", around: "a", context: 20) == "a b")
    }
}
