import Foundation
import Testing

@testable import StillnoteCore

/// The speaker profile commands the CLI answers on its own, and how a `<profile>` resolves.
@Suite struct SpeakerCommandTests {
    private let ada = SpeakerProfile(id: "A1B2C3D4-0000-0000-0000-000000000001", name: "Ada Lovelace",
                                     email: "ada@example.com", phone: "+44 20 1234")
    private let grace = SpeakerProfile(id: "A1B2FFFF-0000-0000-0000-000000000002", name: "Grace Hopper")

    private func library() async throws -> (Store, Paths) {
        let paths = try temporaryPaths()
        let store = try Store(paths: paths)
        try await store.saveProfile(ada)
        try await store.saveProfile(grace)
        for (id, created) in [("m1", "2026-09-01T10:00:00.000+00:00"), ("m2", "2026-09-08T10:00:00.000+00:00")] {
            var meeting = Meeting(id: id, title: "Sync \(id)", audioName: "a.wav", language: "en",
                                  speakerCount: nil, duration: 60)
            meeting.createdAt = created
            meeting.speakers = ["speaker_1": "Ada Lovelace", "speaker_2": "Someone"]
            meeting.segments = [Segment(id: "s0", start: 0, end: 1, speaker: "speaker_1", text: "Hi")]
            meeting.status = .transcribed
            try await store.insert(meeting)
            _ = try await store.assignProfile(ada.id, meetingID: id, speakerID: "speaker_1")
        }
        return (store, paths)
    }

    private func run(_ argv: [String], _ store: Store) async throws -> CLIResponse {
        let invocation = try CommandCatalog.parse(argv)
        #expect(!invocation.spec.requiresApp)
        return try #require(try await CommandRunner.read(invocation.request, store: store))
    }

    @Test func listsProfilesWithMeetingCounts() async throws {
        let (store, paths) = try await library()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let response = try await run(["speaker", "list"], store)
        let payload = try #require(try response.payload?.decoded(SpeakerListPayload.self))
        #expect(payload.count == 2)
        #expect(payload.speakers.map(\.name) == ["Ada Lovelace", "Grace Hopper"])
        #expect(payload.speakers[0].meetingCount == 2)
        #expect(payload.speakers[0].email == "ada@example.com")
        #expect(payload.speakers[0].meetings == nil)
        #expect(payload.speakers[1].meetingCount == 0)
        #expect(response.message.contains("ada@example.com"))
    }

    @Test func showsOneProfileWithItsMeetingsNewestFirst() async throws {
        let (store, paths) = try await library()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let response = try await run(["speaker", "show", "ada lovelace"], store)
        let payload = try #require(try response.payload?.decoded(SpeakerProfilePayload.self))
        #expect(payload.id == ada.id)
        #expect(payload.meetings?.map(\.id) == ["m2", "m1"])
        #expect(payload.meetings?.first?.speaker == "speaker_1")
        #expect(response.message.contains("+44 20 1234"))
    }

    @Test func resolvesByIdNamePrefixAndEmail() throws {
        let profiles = [ada, grace]
        #expect(try SpeakerQuery.resolve(ada.id.lowercased(), in: profiles) == ada)
        #expect(try SpeakerQuery.resolve("GRACE HOPPER", in: profiles) == grace)
        #expect(try SpeakerQuery.resolve("ADA@example.com", in: profiles) == ada)
        #expect(try SpeakerQuery.resolve("a1b2c3", in: profiles) == ada)
        #expect(throws: CLIError.self) { try SpeakerQuery.resolve("a1b2", in: profiles) }
        #expect(throws: CLIError.self) { try SpeakerQuery.resolve("Nobody", in: profiles) }
        let twins = [ada, SpeakerProfile(name: "Ada Lovelace")]
        do {
            _ = try SpeakerQuery.resolve("Ada Lovelace", in: twins)
            Issue.record("Two profiles with one name should be ambiguous")
        } catch let error as CLIError {
            #expect(error.code == .ambiguous)
        }
    }

    @Test func parsesTheChangingCommands() throws {
        let add = try CommandCatalog.parse(["speaker", "add", "--name", "Ada", "--email", "ada@example.com"])
        #expect(add.spec.requiresApp)
        #expect(add.request.value("email") == "ada@example.com")
        let clear = try CommandCatalog.parse(["speaker", "update", "Ada", "--phone", ""])
        #expect(clear.request.positionals == ["Ada"])
        #expect(clear.request.value("phone") == "")
        let assign = try CommandCatalog.parse(["speaker", "assign", "latest", "--speaker", "speaker_1", "--none"])
        #expect(assign.request.has("none"))
        #expect(try CommandCatalog.parse(["speaker", "delete", "Ada"]).spec.requiresApp)
        #expect(throws: CLIError.self) { try CommandCatalog.parse(["speaker", "delete"]) }
    }

    @Test func voicesReportsLearnedAccuracyWithoutVoiceprints() async throws {
        let (store, paths) = try await library()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let empty = try await run(["speaker", "voices"], store)
        #expect(empty.message.contains("No voices learned yet"))
        #expect(try #require(try empty.payload?.decoded(VoiceStatusPayload.self)).learned == false)

        try await store.saveVoiceModel(VoiceModel(
            modelRevision: "r", learnedAt: "2026-11-06T10:00:00.000+00:00",
            rule: VoiceRule(scorer: .nearest, threshold: 0.67, margin: 0.15), calibrated: true,
            metrics: VoiceMetrics(recognizable: 100, strangers: 4, correct: 85, wrong: 2, abstained: 17),
            profileCount: 2, sampleCount: 104, meetingCount: 2, skippedMeetings: 0
        ))
        let learned = try await run(["speaker", "voices"], store)
        let payload = try #require(try learned.payload?.decoded(VoiceStatusPayload.self))
        #expect(payload.learned && payload.calibrated)
        #expect(payload.coverage == 0.85)
        #expect(payload.scorer == "nearest")
        #expect(learned.message.contains("97.7% of matches were right"))
        #expect(!learned.message.contains("vector"))
    }

    @Test func autotagRendersEveryDecision() throws {
        let outcome = AutoTagOutcome(meetingID: "m1", matches: [
            VoiceMatch(speaker: "speaker_1", decision: .assigned, profileID: ada.id, score: 0.91,
                       runnerUpID: grace.id, runnerUpScore: 0.4),
            VoiceMatch(speaker: "speaker_2", decision: .uncertain, profileID: grace.id, score: 0.72,
                       runnerUpID: ada.id, runnerUpScore: 0.68),
            VoiceMatch(speaker: "speaker_3", decision: .unrecognized, profileID: grace.id, score: 0.3),
            VoiceMatch(speaker: "speaker_4", decision: .tooShort),
        ], applied: ["speaker_1"], dryRun: false)
        #expect(outcome.summary == "Matched 1 speaker by voice. 3 weren't recognized.")
        let leftover = AutoTagOutcome(meetingID: "m1", matches: [VoiceMatch(speaker: "speaker_4", decision: .tooShort)],
                                      applied: [], dryRun: false)
        #expect(leftover.summary == "The untagged speaker has too little clear speech to recognize.")
        let names = [ada.id: ada.name, grace.id: grace.name]
        let payload = AutoTagPayload(dryRun: false, meetings: [
            AutoTagMeetingPayload(outcome, title: "Sync", summaryCleared: true, names: names),
        ])
        #expect(payload.tagged == 1)
        let text = try CommandRunner.autoTagResponse(payload).message
        #expect(text.contains("speaker_1 → Ada Lovelace (0.91) linked"))
        #expect(text.contains("speaker_2 uncertain: Grace Hopper (0.72) or Ada Lovelace (0.68)"))
        #expect(text.contains("speaker_3 not recognized (closest: Grace Hopper, 0.30)"))
        #expect(text.contains("speaker_4 has too little clear speech"))
        #expect(text.contains("summary was cleared"))
        let dry = try CommandRunner.autoTagResponse(AutoTagPayload(dryRun: true, meetings: [
            AutoTagMeetingPayload(
                AutoTagOutcome(meetingID: "m1", matches: outcome.matches, applied: [], dryRun: true),
                title: "Sync", summaryCleared: false, names: names
            ),
        ])).message
        #expect(dry.contains("would link"))
        #expect(dry.contains("Dry run: nothing was written"))
    }

    @Test func autotagAllReportsSkippedMeetings() throws {
        let missing = AutoTagSkip(id: "m2", title: "Old call", reason: "This meeting's audio is missing.")
        let onlySkipped = AutoTagPayload(dryRun: false, meetings: [], skipped: [missing])
        let text = try CommandRunner.autoTagResponse(onlySkipped).message
        #expect(text.contains("Skipped 1 meeting(s):"))
        #expect(text.contains("  Old call [m2]: This meeting's audio is missing."))
        #expect(!text.contains("No transcribed meetings have untagged speakers"))

        let json = try JSONEncoder().encode(onlySkipped)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let skipped = try #require(object["skipped"] as? [[String: Any]])
        #expect(skipped.first?["reason"] as? String == missing.reason)
        #expect(try JSONDecoder().decode(AutoTagPayload.self, from: json) == onlySkipped)

        let nothing = try CommandRunner.autoTagResponse(AutoTagPayload(dryRun: false, meetings: [])).message
        #expect(nothing.contains("No transcribed meetings have untagged speakers"))
        #expect(!nothing.contains("Skipped"))
    }

    @Test func helpForAGroupListsEverySubcommand() {
        let text = CommandCatalog.help(command: "speaker")
        for name in ["rename", "list", "show", "add", "update", "delete", "assign", "voices", "learn", "autotag"] {
            #expect(text.contains("stillnote speaker \(name)"))
        }
    }
}
