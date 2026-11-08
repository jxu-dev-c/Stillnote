import Foundation
import Testing

@testable import StillnoteCore

private func meeting(
    _ id: String, status: MeetingStatus, minutes: Double = 30, transcribed: Bool = false,
    createdAt: String = "2026-10-01T12:00:00.000+00:00"
) -> Meeting {
    var meeting = Meeting(
        id: id, title: "Meeting \(id)", audioName: "recording.wav", language: "en", speakerCount: nil,
        duration: minutes * 60, source: .recording
    )
    meeting.createdAt = createdAt
    meeting.status = status
    if transcribed {
        meeting.segments = [Segment(id: "s0", start: 0, end: 5, speaker: "speaker_1", text: "Hello.")]
    }
    return meeting
}

@Suite struct ProcessPlanTests {
    @Test func resumesFromWhereEachMeetingStopped() throws {
        #expect(try ProcessPlan.stage(for: meeting("a", status: .ready)) == .transcribe)
        #expect(try ProcessPlan.stage(for: meeting("b", status: .transcribed, transcribed: true)) == .summarize)
        // A failed summary keeps its transcript; a failed transcription has none.
        #expect(try ProcessPlan.stage(for: meeting("c", status: .error, transcribed: true)) == .summarize)
        #expect(try ProcessPlan.stage(for: meeting("d", status: .error)) == .transcribe)
    }

    @Test func refusesBusyAndFinishedMeetings() {
        #expect(throws: CLIError.self) { try ProcessPlan.stage(for: meeting("a", status: .transcribing)) }
        #expect(throws: CLIError.self) { try ProcessPlan.stage(for: meeting("b", status: .summarizing)) }
        #expect(throws: CLIError.self) { try ProcessPlan.stage(for: meeting("c", status: .complete, transcribed: true)) }
        do {
            _ = try ProcessPlan.stage(for: meeting("d", status: .transcribing))
        } catch let error as CLIError {
            #expect(error.code == .busy)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test func plansSplitsOnlyBeforeTranscription() throws {
        let long = meeting("a", status: .ready, minutes: 90)
        #expect(try ProcessPlan.step(long, splitThresholdMinutes: 50, split: true, name: true).parts == 5)
        #expect(try ProcessPlan.step(long, splitThresholdMinutes: 50, split: false, name: true).parts == 1)
        #expect(try ProcessPlan.step(long, splitThresholdMinutes: 120, split: true, name: true).parts == 1)
        let transcribed = meeting("b", status: .transcribed, minutes: 90, transcribed: true)
        #expect(try ProcessPlan.step(transcribed, splitThresholdMinutes: 50, split: true, name: true).parts == 1)
        #expect(try ProcessPlan.step(long, splitThresholdMinutes: 50, split: true, name: false).named == false)
    }

    @Test func selectsUnfinishedMeetingsNewestFirst() throws {
        let library = [
            meeting("old", status: .ready, createdAt: "2026-05-01T12:00:00.000+00:00"),
            meeting("new", status: .transcribed, transcribed: true, createdAt: "2026-10-01T12:00:00.000+00:00"),
            meeting("done", status: .complete, transcribed: true),
            meeting("busy", status: .transcribing),
            meeting("failed", status: .error),
        ]
        let defaults = ProcessPlan.candidates(library, statuses: try ProcessPlan.statuses(nil), filter: MeetingFilter())
        #expect(defaults.map(\.id) == ["new", "old"])

        let failed = ProcessPlan.candidates(library, statuses: try ProcessPlan.statuses("error"), filter: MeetingFilter())
        #expect(failed.map(\.id) == ["failed"])

        let may = ProcessPlan.candidates(
            library, statuses: ProcessPlan.defaultStatuses,
            filter: MeetingFilter(since: try MeetingQuery.range("2026-05").start, until: try MeetingQuery.range("2026-05").end)
        )
        #expect(may.map(\.id) == ["old"])

        // The limit counts only meetings that would be processed.
        let one = ProcessPlan.candidates(library, statuses: ProcessPlan.defaultStatuses, filter: MeetingFilter(limit: 1))
        #expect(one.map(\.id) == ["new"])
    }

    @Test func acceptsOnlyStatusesThatCanBeProcessed() {
        #expect(throws: CLIError.self) { try ProcessPlan.statuses("complete") }
        #expect(throws: CLIError.self) { try ProcessPlan.statuses("transcribing") }
        #expect(throws: CLIError.self) { try ProcessPlan.statuses("bogus") }
        #expect((try? ProcessPlan.statuses("READY")) == [.ready])
    }

    @Test func parsesTheProcessAndNameCommands() throws {
        let all = try CommandCatalog.parse(
            ["process", "--all", "--status", "ready", "--since", "2026-05", "--limit", "20", "--allow-remote", "--no-split", "--keep-title"]
        )
        #expect(all.spec.path == ["process"])
        #expect(all.spec.requiresApp)
        #expect(all.request.positionals.isEmpty)
        #expect(all.request.has("all") && all.request.has("no-split") && all.request.has("keep-title"))
        #expect(all.request.value("limit") == "20")
        #expect(try CommandCatalog.parse(["process", "latest", "--dry-run"]).request.positionals == ["latest"])
        #expect(try CommandCatalog.parse(["name", "latest", "--allow-remote"]).spec.path == ["name"])
        #expect(throws: CLIError.self) { try CommandCatalog.parse(["name"]) }
    }

    @Test func rendersADryRunAndAQueuedBatch() throws {
        let steps = [
            ProcessStep(id: "a", title: "Long one", stage: .transcribe, parts: 3, named: true),
            ProcessStep(id: "b", title: "Short one", stage: .summarize, parts: 1, named: false),
        ]
        let dry = try CommandRunner.processResponse(ProcessPayload(dryRun: true, meetings: steps))
        #expect(dry.message.contains("Long one [a]: would split into 3 parts, transcribe, summarize, name"))
        #expect(dry.message.contains("Short one [b]: would summarize"))
        #expect(dry.message.contains("Dry run"))

        var queued = steps
        queued[0].queued = ["a1", "a2", "a3"]
        queued[1].queued = ["b"]
        let done = try CommandRunner.processResponse(ProcessPayload(
            dryRun: false, meetings: queued, skipped: [ProcessSkip(id: "c", title: "Gone", reason: "Deleted.")]
        ))
        #expect(done.message.contains("Queued 4 meeting(s)."))
        #expect(done.message.contains("  as a1, a2, a3"))
        #expect(done.message.contains("Skipped 1 meeting(s):"))

        let none = try CommandRunner.processResponse(ProcessPayload(dryRun: false, meetings: []))
        #expect(none.message == "No meetings match. Nothing was queued.")
    }
}
