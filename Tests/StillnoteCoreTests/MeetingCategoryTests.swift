import Foundation
import SQLite3
import Testing

@testable import StillnoteCore

@Suite struct MeetingCategoryTests {
    private func meeting(_ id: String, category: String? = nil) -> Meeting {
        var meeting = Meeting(id: id, title: id, audioName: "a.wav", language: "en", speakerCount: nil, duration: 1)
        meeting.categoryID = category
        return meeting
    }

    @Test func oldDocumentsDecodeUnstarredAndUncategorized() throws {
        let legacy = #"{"id":"m1","title":"Old","created_at":"2025-01-01T00:00:00+00:00","updated_at":"2025-01-01T00:00:00+00:00"}"#
        let decoded = try JSONDecoder().decode(Meeting.self, from: Data(legacy.utf8))
        #expect(!decoded.starred)
        #expect(decoded.categoryID == nil)

        var meeting = decoded
        meeting.starred = true
        meeting.categoryID = "c1"
        let data = try JSONEncoder().encode(meeting)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["starred"] as? Bool == true)
        #expect(object["category_id"] as? String == "c1")
        let reread = try JSONDecoder().decode(Meeting.self, from: data)
        #expect(reread.starred && reread.categoryID == "c1")
        #expect(MeetingListItem(reread).starred && MeetingListItem(reread).categoryID == "c1")
    }

    @Test func sortsManuallyByNameAndByCount() {
        let categories = [
            MeetingCategory(id: "a", name: "customers", color: .blue, position: 2),
            MeetingCategory(id: "b", name: "Design", color: .green, position: 0),
            MeetingCategory(id: "c", name: "1:1s", color: .pink, position: 1),
            MeetingCategory(id: "d", name: "Product", color: .orange, position: 3),
        ]
        #expect(MeetingCategory.sorted(categories, by: .manual).map(\.id) == ["b", "c", "a", "d"])
        #expect(MeetingCategory.sorted(categories, by: .name).map(\.id) == ["c", "a", "b", "d"])
        // Ties fall back to name order; categories with no meetings count as zero.
        let counts = ["a": 3, "b": 5, "c": 3]
        #expect(MeetingCategory.sorted(categories, by: .count, counts: counts).map(\.id) == ["b", "c", "a", "d"])
    }

    @Test func colorsRotateAndUnknownTokensReadAsGray() throws {
        #expect(CategoryColor.next(after: []) == .blue)
        #expect(CategoryColor.next(after: [.blue, .purple]) == .orange)
        let all = CategoryColor.allCases.filter { $0 != .gray }
        #expect(CategoryColor.next(after: all) == all[0])

        let json = #"{"id":"c1","name":"Ops","color":"chartreuse","position":0}"#
        #expect(try JSONDecoder().decode(MeetingCategory.self, from: Data(json.utf8)).color == .gray)
    }

    @Test func validatesNames() throws {
        #expect(try Validation.categoryName("  Product  ") == "Product")
        #expect(throws: ValidationError.self) { try Validation.categoryName("   ") }
        #expect(throws: ValidationError.self) {
            try Validation.categoryName(String(repeating: "x", count: Validation.maxCategoryNameLength + 1))
        }
    }

    @Test func storeSavesReordersAndDeletes() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)

        let product = try await store.saveCategory(MeetingCategory(id: "p", name: " Product ", color: .blue, position: 0))
        #expect(product.name == "Product")
        try await store.saveCategory(MeetingCategory(id: "d", name: "Design", color: .purple, position: 1))
        await #expect(throws: ValidationError.self) {
            try await store.saveCategory(MeetingCategory(id: "x", name: "", color: .red, position: 2))
        }
        #expect(try await store.categories().map(\.id) == ["p", "d"])

        let reordered = try await store.reorderCategories(["d", "p"])
        #expect(reordered.map(\.position) == [0, 1])
        #expect(try await store.categories().map(\.id) == ["d", "p"])

        try await store.insert(meeting("m1", category: "p"))
        try await store.insert(meeting("m2", category: "d"))
        try await store.insert(meeting("m3"))
        let changed = try await store.deleteCategory("p")
        #expect(changed.map(\.id) == ["m1"])
        #expect(try await store.get("m1").categoryID == nil)
        #expect(try await store.get("m2").categoryID == "d")
        #expect(try await store.libraryItem("m1").categoryID == nil)
        #expect(try await store.libraryItem("m2").categoryID == "d")
        #expect(try await store.categories().map(\.id) == ["d"])
    }

    /// The CLI opens libraries read-only; one written before categories has no table.
    @Test func readOnlyLibraryWithoutCategoriesTable() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        var database: OpaquePointer?
        #expect(sqlite3_open(paths.databaseURL.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "CREATE TABLE meetings (id TEXT PRIMARY KEY, data TEXT NOT NULL)", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        let reader = try Store(paths: paths, readOnly: true)
        #expect(try await reader.categories().isEmpty)
    }
}
