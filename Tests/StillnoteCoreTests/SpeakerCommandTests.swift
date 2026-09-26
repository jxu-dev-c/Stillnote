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

    @Test func helpForAGroupListsEverySubcommand() {
        let text = CommandCatalog.help(command: "speaker")
        for name in ["rename", "list", "show", "add", "update", "delete", "assign"] {
            #expect(text.contains("stillnote speaker \(name)"))
        }
    }
}
