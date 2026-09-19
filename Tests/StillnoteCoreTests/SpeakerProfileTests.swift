import Foundation
import Testing
@testable import StillnoteCore

@Suite struct SpeakerProfileTests {
    private func meeting(_ id: String) -> Meeting {
        var result = Meeting(id: id, title: id, audioName: "a.wav", language: "en", speakerCount: nil, duration: 3)
        result.speakers = ["s1": "Ada"]
        result.segments = [Segment(id: "one", start: 0, end: 1, speaker: "s1", text: "Hello")]
        result.status = .complete
        result.summary = MeetingSummary(overview: "Hello", keyPoints: [], decisions: [], actionItems: [],
                                       provider: "test", model: "test", generatedAt: Meeting.now())
        return result
    }

    @Test func profilesPersistAndAreReusedWithoutChangingSnapshots() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        try await store.insert(meeting("a"))
        try await store.insert(meeting("b"))
        var profile = SpeakerProfile(name: " Ada ", email: " ada@example.com ", phone: " +44 (20) 1234 ")
        let first = try await store.createProfile(profile, meetingID: "a", speakerID: "s1")
        #expect(first.summary != nil)
        #expect(first.speakerProfiles["s1"] == profile.id)
        profile.name = "Ada Lovelace"
        try await store.saveProfile(profile)
        let second = try await store.assignProfile(profile.id, meetingID: "b", speakerID: "s1")
        #expect(second.speakerName("s1") == "Ada Lovelace")
        #expect(second.summary == nil)
        #expect(second.status == .transcribed)
        #expect(try await store.get("a").speakerName("s1") == "Ada")
        #expect(try await store.get("a").summary != nil)
        let reopened = try Store(paths: paths)
        #expect(try await reopened.profiles().first?.email == "ada@example.com")
        #expect(try await reopened.profiles().first?.phone == "+44 (20) 1234")
        let unlinked = try await store.assignProfile(nil, meetingID: "a", speakerID: "s1")
        #expect(unlinked.speakerProfiles.isEmpty)
        #expect(unlinked.summary != nil)
        #expect(unlinked.speakerName("s1") == "Ada")
        let renamed = try await store.assignProfile(nil, meetingID: "b", speakerID: "s1", localName: "Local")
        #expect(renamed.speakerProfiles.isEmpty)
        #expect(renamed.speakerName("s1") == "Local")
        try await store.delete("a")
        try await store.delete("b")
        #expect(try await store.profiles().count == 1)
    }

    @Test func failedAssignmentRollsBackCreationAndBusyMeetingsRejectChanges() async throws {
        let store = try Store(paths: temporaryPaths())
        try await store.insert(meeting("a"))
        try await store.update("a") { $0.status = .transcribing }
        do {
            _ = try await store.createProfile(SpeakerProfile(name: "New"), meetingID: "a", speakerID: "s1")
            Issue.record("Expected busy meeting rejection")
        } catch {}
        #expect(try await store.profiles().isEmpty)
        do {
            _ = try await store.assignProfile(nil, meetingID: "a", speakerID: "s1", localName: "Changed")
            Issue.record("Expected busy meeting rejection")
        } catch {}
        #expect(try await store.get("a").speakerName("s1") == "Ada")
    }

    @Test func migratesNamedSpeakersOnceWithoutMergingOrChangingSummaries() async throws {
        let store = try Store(paths: temporaryPaths())
        var first = meeting("a")
        first.speakers["s2"] = "Speaker 2"
        first.speakers["s3"] = "Unknown speaker"
        try await store.insert(first)
        try await store.insert(meeting("b"))
        try await store.migrateNamedSpeakers()
        let a = try await store.get("a")
        let b = try await store.get("b")
        #expect(try await store.profiles().count == 2)
        #expect(a.speakerProfiles.count == 1)
        #expect(a.speakerProfiles["s1"] != b.speakerProfiles["s1"])
        #expect(a.summary == first.summary)
        #expect(a.speakers == first.speakers)
        #expect(a.updatedAt == first.updatedAt)
        _ = try await store.assignProfile(nil, meetingID: "a", speakerID: "s1")
        try await store.migrateNamedSpeakers()
        #expect(try await store.get("a").speakerProfiles.isEmpty)
        #expect(try await store.profiles().count == 2)
    }

    @Test func deletingProfilePreservesMeetingsAndOtherProfiles() async throws {
        let paths = try temporaryPaths()
        let store = try Store(paths: paths)
        try await store.insert(meeting("a"))
        try await store.insert(meeting("b"))
        let profile = try await store.saveProfile(SpeakerProfile(name: "Ada"))
        let other = try await store.saveProfile(SpeakerProfile(name: "Ada"))
        let a = try await store.assignProfile(profile.id, meetingID: "a", speakerID: "s1")
        _ = try await store.assignProfile(profile.id, meetingID: "b", speakerID: "s1")
        _ = try await store.update("b") { $0.status = .summarizing }
        let changed = try await store.deleteProfile(profile.id)
        #expect(changed.count == 2)
        let reopened = try Store(paths: paths)
        #expect(try await reopened.profiles().map(\.id) == [other.id])
        let loaded = try await reopened.get("a")
        #expect(loaded.speakerProfiles.isEmpty)
        #expect(loaded.speakers == a.speakers)
        #expect(loaded.summary == a.summary)
        #expect(try await reopened.get("b").status == .summarizing)
        #expect(try await reopened.get("b").speakerProfiles.isEmpty)
    }

    @Test func validationAndDuplicateNames() async throws {
        #expect(throws: ValidationError.self) { try SpeakerProfile(name: " ").validated() }
        #expect(throws: ValidationError.self) { try SpeakerProfile(name: "Ada", email: "invalid").validated() }
        let store = try Store(paths: temporaryPaths())
        try await store.saveProfile(SpeakerProfile(name: "Ada"))
        try await store.saveProfile(SpeakerProfile(name: "Ada"))
        #expect(try await store.profiles().count == 2)
        #expect(try await store.profiles().allSatisfy { $0.email.isEmpty && $0.phone.isEmpty })
    }
}
