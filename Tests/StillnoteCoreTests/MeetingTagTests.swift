import Foundation
import SQLite3
import Testing

@testable import StillnoteCore

@Suite struct MeetingTagTests {
    private func meeting(_ id: String, tags: [String] = []) -> Meeting {
        var meeting = Meeting(id: id, title: id, audioName: "a.wav", language: "en", speakerCount: nil, duration: 1)
        meeting.tagIDs = tags
        return meeting
    }

    private static let header = #""id":"m1","title":"Old","created_at":"2025-01-01T00:00:00+00:00","updated_at":"2025-01-01T00:00:00+00:00""#

    @Test func oldDocumentsDecodeUnstarredAndUntagged() throws {
        let legacy = "{\(Self.header)}"
        let decoded = try JSONDecoder().decode(Meeting.self, from: Data(legacy.utf8))
        #expect(!decoded.starred)
        #expect(decoded.tagIDs.isEmpty)

        var meeting = decoded
        meeting.starred = true
        meeting.tagIDs = ["c1", "c2"]
        let data = try JSONEncoder().encode(meeting)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["starred"] as? Bool == true)
        #expect(object["tag_ids"] as? [String] == ["c1", "c2"])
        // A build from before tags reads the first one.
        #expect(object["category_id"] as? String == "c1")
        let reread = try JSONDecoder().decode(Meeting.self, from: data)
        #expect(reread.starred && reread.tagIDs == ["c1", "c2"])
        #expect(MeetingListItem(reread).starred && MeetingListItem(reread).tagIDs == ["c1", "c2"])

        meeting.tagIDs = []
        let cleared = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(meeting)) as? [String: Any])
        #expect(cleared["category_id"] == nil)
        #expect(cleared["tag_ids"] as? [String] == [])
    }

    @Test func singleCategoryDocumentsReadAsOneTag() throws {
        let legacy = #"{\#(Self.header),"category_id":"c1"}"#
        #expect(try JSONDecoder().decode(Meeting.self, from: Data(legacy.utf8)).tagIDs == ["c1"])
        // tag_ids wins; an older build's category_id is only a fallback.
        let both = #"{\#(Self.header),"category_id":"c9","tag_ids":["c2","c2","","c3"]}"#
        #expect(try JSONDecoder().decode(Meeting.self, from: Data(both.utf8)).tagIDs == ["c2", "c3"])
    }

    @Test func addsAndRemovesTagsWithoutRepeats() {
        var meeting = meeting("m1", tags: ["a"])
        #expect(meeting.addTags(["b", "a", "b", "c"]) == ["b", "c"])
        #expect(meeting.tagIDs == ["a", "b", "c"])
        meeting.removeTag("a")
        #expect(meeting.tagIDs == ["b", "c"])
        #expect(MeetingTag.names(of: ["c", "gone", "b"], in: [
            MeetingTag(id: "b", name: "Beta", color: .blue, position: 0),
            MeetingTag(id: "c", name: "Gamma", color: .red, position: 1),
        ]) == ["Gamma", "Beta"])
    }

    @Test func sortsManuallyByNameAndByCount() {
        let categories = [
            MeetingTag(id: "a", name: "customers", color: .blue, position: 2),
            MeetingTag(id: "b", name: "Design", color: .green, position: 0),
            MeetingTag(id: "c", name: "1:1s", color: .pink, position: 1),
            MeetingTag(id: "d", name: "Product", color: .orange, position: 3),
        ]
        #expect(MeetingTag.sorted(categories, by: .manual).map(\.id) == ["b", "c", "a", "d"])
        #expect(MeetingTag.sorted(categories, by: .name).map(\.id) == ["c", "a", "b", "d"])
        // Ties fall back to name order; categories with no meetings count as zero.
        let counts = ["a": 3, "b": 5, "c": 3]
        #expect(MeetingTag.sorted(categories, by: .count, counts: counts).map(\.id) == ["b", "c", "a", "d"])
    }

    @Test func colorsRotateAndUnknownTokensReadAsGray() throws {
        #expect(TagColor.next(after: []) == .blue)
        #expect(TagColor.next(after: [.blue, .purple]) == .orange)
        let all = TagColor.allCases.filter { $0 != .gray }
        #expect(TagColor.next(after: all) == all[0])

        let json = #"{"id":"c1","name":"Ops","color":"chartreuse","position":0}"#
        #expect(try JSONDecoder().decode(MeetingTag.self, from: Data(json.utf8)).color == .gray)
    }

    @Test func validatesNames() throws {
        #expect(try Validation.tagName("  Product  ") == "Product")
        #expect(throws: ValidationError.self) { try Validation.tagName("   ") }
        #expect(throws: ValidationError.self) {
            try Validation.tagName(String(repeating: "x", count: Validation.maxTagNameLength + 1))
        }
    }

    @Test func storeSavesReordersAndDeletes() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)

        let product = try await store.saveTag(MeetingTag(id: "p", name: " Product ", color: .blue, position: 0))
        #expect(product.name == "Product")
        try await store.saveTag(MeetingTag(id: "d", name: "Design", color: .purple, position: 1))
        await #expect(throws: ValidationError.self) {
            try await store.saveTag(MeetingTag(id: "x", name: "", color: .red, position: 2))
        }
        #expect(try await store.tags().map(\.id) == ["p", "d"])

        let reordered = try await store.reorderTags(["d", "p"])
        #expect(reordered.map(\.position) == [0, 1])
        #expect(try await store.tags().map(\.id) == ["d", "p"])

        try await store.insert(meeting("m1", tags: ["p"]))
        try await store.insert(meeting("m2", tags: ["d"]))
        try await store.insert(meeting("m3"))
        try await store.insert(meeting("m4", tags: ["d", "p"]))
        let changed = try await store.deleteTag("p")
        #expect(Set(changed.map(\.id)) == ["m1", "m4"])
        #expect(try await store.get("m1").tagIDs.isEmpty)
        #expect(try await store.get("m2").tagIDs == ["d"])
        #expect(try await store.get("m4").tagIDs == ["d"])
        #expect(try await store.libraryItem("m1").tagIDs.isEmpty)
        #expect(try await store.libraryItem("m4").tagIDs == ["d"])
        #expect(try await store.tags().map(\.id) == ["d"])
    }

    @Test func restoringADeletedMeetingDropsTagsDeletedMeanwhile() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        try await store.saveTag(MeetingTag(id: "keep", name: "Keep", color: .blue, position: 0))
        try await store.saveTag(MeetingTag(id: "drop", name: "Drop", color: .red, position: 1))
        try await store.insert(meeting("m1", tags: ["drop", "keep"]))
        try await store.moveToRecentlyDeleted("m1")
        _ = try await store.deleteTag("drop")
        let restored = try await store.restoreDeleted("m1")
        #expect(restored.tagIDs == ["keep"])
        #expect(try await store.get("m1").tagIDs == ["keep"])
    }

    /// The CLI opens libraries read-only; one written before tags (then categories) has no table.
    @Test func readOnlyLibraryWithoutCategoriesTable() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        var database: OpaquePointer?
        #expect(sqlite3_open(paths.databaseURL.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE meetings (id TEXT PRIMARY KEY, data TEXT NOT NULL)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        let reader = try Store(paths: paths, readOnly: true)
        #expect(try await reader.tags().isEmpty)
    }
}
