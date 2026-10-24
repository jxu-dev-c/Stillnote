import Foundation
import SQLite3
import Testing
@testable import StillnoteCore

@Suite struct LibraryStoreTests {
    private func meeting(_ id: String = "a") -> Meeting {
        var m = Meeting(id: id, title: "DESIGN Café", audioName: "test.wav", language: "en", speakerCount: nil, duration: 3600)
        m.notes = "Private notes"
        m.segments = [Segment(id: "1", start: 0, end: 1, speaker: "s", text: "Launch 产品"),
                      Segment(id: "2", start: 1, end: 2, speaker: "s", text: "计划 tomorrow")]
        m.speakers = ["s": "Speaker"]
        return m
    }

    private func sql(_ paths: Paths, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(paths.databaseURL.path, &db) == SQLITE_OK else { throw StoreError.open("test") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.query(String(cString: sqlite3_errmsg(db)))
        }
    }

    @Test func indexTracksAllWritesAndKeepsDetailsSeparate() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        let original = meeting()
        try await store.insert(original)
        let first = try await store.libraryItem("a")
        #expect(first.title == original.title)
        #expect(first.startDate == original.startDate)
        #expect(try await store.snapshot("a").meeting == original)
        let reader = try Store(paths: paths, readOnly: true)
        for query in ["  design  ", "产品 计划", "cafe\u{301}", "café launch"] {
            #expect(try await reader.searchLibrary(query) == ["a"])
        }
        try await store.update("a") { $0.progress = 42; $0.notes = "Edited notes" }
        let progress = try await store.libraryItem("a")
        #expect(progress.revision > first.revision)
        #expect(progress.searchRevision == first.searchRevision)
        #expect(try await reader.searchLibrary("edited notes").isEmpty)
        try await store.update("a") { $0.segments[0].text = "Corrected transcript" }
        #expect(try await store.libraryItem("a").searchRevision > progress.searchRevision)
        #expect(try await reader.searchLibrary("产品").isEmpty)
        #expect(try await reader.searchLibrary("corrected transcript") == ["a"])
        try await store.delete("a")
        #expect(try await store.libraryItems().isEmpty)
        #expect(try await reader.searchLibrary("corrected").isEmpty)
    }

    @Test func legacyMigrationAndLegacyWritesRemainSearchable() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let json = String(decoding: try JSONEncoder().encode(meeting()), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
        try sql(paths, "CREATE TABLE meetings(id TEXT PRIMARY KEY,data TEXT NOT NULL); INSERT INTO meetings VALUES ('a','\(json)');")
        let store = try Store(paths: paths)
        #expect(try await store.libraryItems().count == 1)
        try await store.prepareLibrarySearch()
        #expect(try await store.searchLibrary("design") == ["a"])
        try sql(paths, "UPDATE meetings SET data=json_set(data,'$.title','Legacy Rename') WHERE id='a';")
        #expect(try await store.libraryItem("a").title == "Legacy Rename")
        let reader = try Store(paths: paths, readOnly: true)
        // Invalidated caches are correct even before the next writable launch rebuilds them.
        #expect(try await reader.searchLibrary("legacy rename") == ["a"])
        #expect(try await reader.searchLibrary("design").isEmpty)
        try await store.prepareLibrarySearch()
        #expect(try await store.get("a").notes == "Private notes")
        try sql(paths, "DELETE FROM meetings WHERE id='a';")
        #expect(try await store.libraryItems().isEmpty)
    }

    @Test func malformedDocumentsDoNotBreakIndexRecovery() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        try sql(paths, "INSERT INTO meetings VALUES ('bad','not json'); INSERT INTO meetings VALUES ('missing','{}'); UPDATE meetings SET data='still invalid' WHERE id='bad';")
        var busy = meeting("busy"); busy.status = .summarizing
        try await store.insert(busy)
        let recovered = try await store.markInterruptedJobs()
        #expect(recovered.map(\.id) == ["busy"])
        #expect(try await store.libraryItem("busy").status == .error)
        try await store.prepareLibrarySearch()
        #expect(try await store.libraryItems().count == 1)
        #expect(try await store.searchLibrary("design") == ["busy"])
    }

    @Test func rolledBackSplitAlsoRollsBackLibraryAndSearch() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        let original = meeting("original")
        try await store.insert(original)
        let part = meeting("part")
        await #expect(throws: Error.self) { try await store.replaceWithSplit(original: original, parts: [part, part]) }
        #expect(try await store.libraryItems().map(\.id) == ["original"])
        #expect(try await store.searchLibrary("design") == ["original"])
        try await store.replaceWithSplit(original: original, parts: [part, meeting("part2")])
        #expect(try await store.searchLibrary("design") == ["part", "part2"])
    }

    @Test func unicodeCandidatesPreserveOriginalSubstringSemantics() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        let texts = ["Café", "cafe\u{301}", "a\u{301}\u{0327}b", "a\u{0327}\u{301}b",
                     "\u{037E}", "Kelvin", "ﬃ", "가나다", "가나다", "👩🏽‍💻 hello", "🇨🇦", "İstanbul", "产品计划", "before\u{0}after"]
        for (i, text) in texts.enumerated() {
            var m = meeting(String(i)); m.title = text; m.segments = []
            try await store.insert(m)
        }
        var queries: Set<String> = [";", "cafe", "café", "kelvin", "ffi", "i", " ", "不存在"]
        for text in texts {
            let scalars = Array(text.unicodeScalars)
            for start in scalars.indices {
                for end in (start + 1)...scalars.count {
                    queries.insert(String(String.UnicodeScalarView(scalars[start..<end])))
                }
            }
        }
        for query in queries {
            let normalized = query.trimmingCharacters(in: .whitespaces).lowercased()
            let expected = Set(texts.enumerated().filter { normalized.isEmpty || $0.element.lowercased().contains(normalized) }.map { String($0.offset) })
            #expect(try await store.searchLibrary(query) == expected, "Query: \(query.debugDescription)")
        }
    }

    @Test func encoderKeyOrderAndSpeakerOnlyChangesDoNotInvalidateSearch() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let seed = try Store(paths: paths)
        try await seed.insert(meeting())
        let writer = try Store(paths: paths)
        let before = try await writer.libraryItem("a")
        try await writer.update("a") { $0.progress = 20; $0.segments[0].speaker = "other" }
        #expect(try await writer.libraryItem("a").searchRevision == before.searchRevision)
        #expect(try await writer.searchLibrary("产品 计划") == ["a"])
    }

    @Test func cancelledSearchDoesNotReturnResults() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        try await store.insert(meeting())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.searchLibrary("design")
        }
        do { _ = try await task.value; Issue.record("Cancelled search returned results") }
        catch { #expect(error is CancellationError) }
    }
}
