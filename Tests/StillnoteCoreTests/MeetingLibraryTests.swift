import Foundation
import Testing
@testable import StillnoteCore

@Suite struct MeetingLibraryTests {
    private func item(_ id: String, date: String = "2026-01-01", title: String = "Design", revision: Int64 = 1) -> MeetingListItem {
        var value = Meeting(id: id, title: title, audioName: "test.wav", language: "en", speakerCount: nil, duration: 3600)
        value.createdAt = date
        return MeetingListItem(value, revision: revision)
    }

    @Test func updatesPreserveOrderAndRejectStaleSnapshots() {
        var meetings = [item("new", date: "2026-02-01"), item("a"), item("b")]
        #expect(MeetingLibrary.apply(item("a", title: "Renamed", revision: 3), to: &meetings))
        #expect(meetings.map(\.id) == ["new", "a", "b"])
        #expect(!MeetingLibrary.apply(item("a", title: "Stale", revision: 2), to: &meetings))
        #expect(meetings[1].title == "Renamed")
    }

    @Test func insertionAndDateChangesMaintainDescendingStableOrder() {
        var meetings = [item("a"), item("b")]
        MeetingLibrary.apply(item("c"), to: &meetings)
        #expect(meetings.map(\.id) == ["a", "b", "c"])
        MeetingLibrary.apply(item("new", date: "2026-02-01"), to: &meetings)
        MeetingLibrary.apply(item("old", date: "2025-01-01"), to: &meetings)
        MeetingLibrary.apply(item("b", date: "2026-03-01", revision: 2), to: &meetings)
        #expect(meetings.map(\.id) == ["b", "new", "a", "c", "old"])
    }

    @Test func searchTextIncludesTitleTranscriptSummaryAndNotes() {
        var meeting = Meeting(id: "m1", title: "Q3 Planning", audioName: "test.wav", language: "en", speakerCount: nil, duration: 60)
        meeting.segments = [Segment(id: "s1", start: 0, end: 1, speaker: "spk_1", text: "Hello team")]
        meeting.summary = MeetingSummary(
            overview: "Synthesized overview phrase",
            keyPoints: ["Latency target under 50ms"],
            decisions: ["Adopt SQLite WAL mode"],
            actionItems: [ActionItem(text: "Draft RFC", owner: "Alice", due: "Friday")],
            provider: "openai",
            model: "gpt-5",
            generatedAt: "2026-04-01T00:00:00+00:00"
        )
        meeting.notes = "Check Café budget"

        let text = MeetingLibrary.searchText(meeting)
        for term in [
            "q3 planning",
            "hello team",
            "synthesized overview phrase",
            "latency target under 50ms",
            "adopt sqlite wal mode",
            "draft rfc",
            "alice",
            "check café budget",
        ] {
            #expect(text.contains(MeetingLibrary.normalizedQuery(term)))
        }
    }
}
