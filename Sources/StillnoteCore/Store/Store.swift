import Foundation
import SQLite3

public enum StoreError: LocalizedError {
    case open(String)
    case query(String)
    case notFound
    case readOnly

    public var errorDescription: String? {
        switch self {
        case .open(let detail): return "Could not open the local database: \(detail)"
        case .query(let detail): return "The local database rejected a change: \(detail)"
        case .notFound: return "Meeting not found."
        case .readOnly: return "This database was opened for reading only."
        }
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local SQLite store. Meetings and settings retain the legacy JSON document schema;
/// reusable speaker profiles live in an additional table.
public actor Store {
    public let paths: Paths
    /// Checkable without awaiting the actor, so a caller can branch before it queries.
    public nonisolated let readOnly: Bool
    private var handle: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Opening read-only never creates a database, a directory, or a table, and rejects every
    /// write. It exists for the `stillnote` CLI, which must be able to answer a question about
    /// an existing library without conjuring an empty one at a mistaken path — and without
    /// running the migrations or recovery that belong to the app.
    public init(paths: Paths, readOnly: Bool = false) throws {
        self.paths = paths
        self.readOnly = readOnly
        if readOnly {
            guard FileManager.default.fileExists(atPath: paths.databaseURL.path) else {
                throw StoreError.open("no meeting library was found at \(paths.databaseURL.path)")
            }
        } else {
            try paths.createDirectories()
        }
        var database: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(paths.databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database
        else {
            throw StoreError.open(String(cString: sqlite3_errmsg(database)))
        }
        handle = database
        sqlite3_busy_timeout(database, 30_000)
        guard !readOnly else { return }
        try Store.run(database, "PRAGMA journal_mode=WAL")
        try Store.run(database, "CREATE TABLE IF NOT EXISTS meetings (id TEXT PRIMARY KEY, data TEXT NOT NULL)")
        try Store.run(database, "CREATE TABLE IF NOT EXISTS speaker_profiles (id TEXT PRIMARY KEY, data TEXT NOT NULL)")
        try Store.run(database, "CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY, data TEXT NOT NULL)")
        try Store.run(database, "CREATE TABLE IF NOT EXISTS categories (id TEXT PRIMARY KEY, data TEXT NOT NULL)")
        try Store.run(database, "CREATE TABLE IF NOT EXISTS deleted_meetings (id TEXT PRIMARY KEY, data TEXT NOT NULL, deleted_at REAL NOT NULL, voiceprints TEXT)")
        try Self.prepareVoiceTables(database)
        try Self.prepareLibrary(database)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.databaseURL.path)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    // MARK: - SQL plumbing

    private static func run(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            defer { sqlite3_free(message) }
            throw StoreError.query(message.map { String(cString: $0) } ?? sql)
        }
    }

    private func database() throws -> OpaquePointer {
        guard let handle else { throw StoreError.open("the database is closed") }
        return handle
    }

    private func execute(_ sql: String, _ bindings: [String]) throws {
        guard !readOnly else { throw StoreError.readOnly }
        let database = try self.database()
        let meetingID: String?
        if sql.hasPrefix("INSERT INTO meetings") { meetingID = bindings.first }
        else if sql.hasPrefix("UPDATE meetings SET data=") { meetingID = bindings.last }
        else { meetingID = nil }
        // Savepoints compose with profile/split transactions and keep the derived search
        // document in the same commit as the authoritative meeting.
        if meetingID != nil { try Self.run(database, "SAVEPOINT library_write") }
        do {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
                throw StoreError.query(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            for (index, value) in bindings.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), value, Int32(value.utf8.count), transient)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw StoreError.query(String(cString: sqlite3_errmsg(database)))
            }
            if let meetingID {
                try refreshSearchText(meetingID)
                try Self.run(database, "RELEASE library_write")
            }
        } catch {
            if meetingID != nil {
                try? Self.run(database, "ROLLBACK TO library_write")
                try? Self.run(database, "RELEASE library_write")
            }
            throw error
        }
    }

    private func documents(_ sql: String, _ bindings: [String] = []) throws -> [Data] {
        let database = try self.database()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.query(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, Int32(value.utf8.count), transient)
        }
        var rows: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                rows.append(Data(String(cString: text).utf8))
            }
        }
        return rows
    }

    // MARK: - Derived library index

    /// The list's copy of a meeting: the document without its heavy fields, plus a short
    /// `snippet` (the summary overview, or the first transcript line) for the meeting list.
    private static func libraryData(_ row: String) -> String {
        """
        CASE WHEN json_valid(\(row).data) THEN json_set(json_remove(\(row).data,
            '$.segments', '$.summary', '$.notes', '$.context_links'), '$.snippet',
            substr(coalesce(nullif(trim(json_extract(\(row).data, '$.summary.overview')), ''),
                json_extract(\(row).data, '$.segments[0].text'), ''), 1, 160)) ELSE '{}' END
        """
    }

    private static let libraryTriggers = """
        CREATE TRIGGER meeting_library_insert AFTER INSERT ON meetings BEGIN
            INSERT OR REPLACE INTO meeting_library VALUES (NEW.id, \(libraryData("NEW")), 1, 1, NULL);
        END;
        CREATE TRIGGER meeting_library_update AFTER UPDATE ON meetings BEGIN
            UPDATE meeting_library SET
                data = \(libraryData("NEW")),
                revision = revision + 1,
                search_revision = search_revision + CASE WHEN
                    CASE WHEN json_valid(OLD.data) AND json_valid(NEW.data)
                    THEN json_extract(OLD.data, '$.title') = json_extract(NEW.data, '$.title')
                        AND (SELECT json_group_array(json_extract(value, '$.text')) FROM json_each(OLD.data, '$.segments'))
                            = (SELECT json_group_array(json_extract(value, '$.text')) FROM json_each(NEW.data, '$.segments'))
                    ELSE 0 END
                    THEN 0 ELSE 1 END,
                search_text = CASE WHEN
                    CASE WHEN json_valid(OLD.data) AND json_valid(NEW.data)
                    THEN json_extract(OLD.data, '$.title') = json_extract(NEW.data, '$.title')
                        AND (SELECT json_group_array(json_extract(value, '$.text')) FROM json_each(OLD.data, '$.segments'))
                            = (SELECT json_group_array(json_extract(value, '$.text')) FROM json_each(NEW.data, '$.segments'))
                    ELSE 0 END
                    THEN search_text ELSE NULL END
            WHERE id = OLD.id;
        END;
        CREATE TRIGGER meeting_library_delete AFTER DELETE ON meetings BEGIN
            DELETE FROM meeting_library WHERE id = OLD.id;
        END;
        """

    /// SQLite triggers also cover writes from older app versions. The original two-column
    /// meetings table remains authoritative, so downgrades and CLI readers stay compatible.
    private static func prepareLibrary(_ db: OpaquePointer) throws {
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT sql FROM sqlite_master WHERE name IN ('meeting_library', 'meeting_library_update') ORDER BY name", -1, &statement, nil)
        var definitions: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            definitions.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
        }
        sqlite3_finalize(statement)
        let exists = !definitions.isEmpty
        // Libraries indexed before the meeting list showed snippets get the current triggers,
        // and every row its snippet, once. Revisions are left alone: nothing visible changed.
        if exists, definitions.contains(where: { $0.contains("'$.snippet'") }) { return }
        try run(db, "BEGIN IMMEDIATE")
        do {
            if exists {
                try run(db, """
                    DROP TRIGGER IF EXISTS meeting_library_insert;
                    DROP TRIGGER IF EXISTS meeting_library_update;
                    DROP TRIGGER IF EXISTS meeting_library_delete;
                    \(libraryTriggers)
                    UPDATE meeting_library SET data = (SELECT \(libraryData("m")) FROM meetings m WHERE m.id = meeting_library.id);
                    COMMIT;
                    """)
            } else {
                try run(db, """
                    CREATE TABLE meeting_library (
                        id TEXT PRIMARY KEY, data TEXT NOT NULL,
                        revision INTEGER NOT NULL, search_revision INTEGER NOT NULL, search_text TEXT
                    );
                    CREATE INDEX meeting_library_date ON meeting_library(json_extract(data, '$.created_at') DESC);
                    CREATE INDEX meeting_library_pending ON meeting_library(id) WHERE search_text IS NULL;
                    \(libraryTriggers)
                    INSERT INTO meeting_library SELECT id, \(libraryData("meetings")), 1, 1, NULL FROM meetings;
                    COMMIT;
                    """)
            }
        } catch {
            try? run(db, "ROLLBACK")
            throw error
        }
    }

    /// Complete/rebuild only invalidated search documents, one meeting at a time.
    /// This is a one-time cost for legacy libraries, not a resident in-memory index.
    public func prepareLibrarySearch() throws {
        let ids = try documents("SELECT id FROM meeting_library WHERE search_text IS NULL")
            .map { String(decoding: $0, as: UTF8.self) }
        for id in ids {
            try Task.checkCancellation()
            try refreshSearchText(id)
        }
    }

    private func refreshSearchText(_ id: String) throws {
        guard let data = try documents("""
            SELECT m.data FROM meetings m JOIN meeting_library l ON l.id=m.id
            WHERE m.id=? AND l.search_text IS NULL
            """, [id]).first else { return }
        let meeting = try? decoder.decode(Meeting.self, from: data)
        let text = meeting.map(MeetingLibrary.searchText) ?? ""
        try execute("UPDATE meeting_library SET search_text=? WHERE id=?", [text, id])
    }

    public func libraryItems() throws -> [MeetingListItem] {
        try libraryRows().map(\.item)
    }

    private func libraryRows(_ id: String? = nil) throws -> [(record: Meeting, item: MeetingListItem)] {
        let db = try database()
        var statement: OpaquePointer?
        let sql = "SELECT data, revision, search_revision, json_extract(data, '$.snippet') FROM meeting_library"
            + (id == nil ? " ORDER BY json_extract(data, '$.created_at') DESC" : " WHERE id=?")
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        if let id { sqlite3_bind_text(statement, 1, id, -1, transient) }
        var result: [(Meeting, MeetingListItem)] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0),
               let record = try? decoder.decode(Meeting.self, from: Data(String(cString: text).utf8)) {
                let snippet = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
                result.append((record, MeetingListItem(record, revision: sqlite3_column_int64(statement, 1),
                                                      searchRevision: sqlite3_column_int64(statement, 2),
                                                      snippet: snippet)))
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw StoreError.query(String(cString: sqlite3_errmsg(db))) }
        return result
    }

    public func libraryItem(_ id: String) throws -> MeetingListItem {
        guard let row = try libraryRows(id).first else { throw StoreError.notFound }
        return row.item
    }

    public func snapshot(_ id: String) throws -> MeetingSnapshot {
        // There is one writer (this actor); no actor suspension separates these reads.
        MeetingSnapshot(meeting: try get(id), item: try libraryItem(id))
    }

    public func resolveMeeting(_ reference: String) throws -> Meeting {
        let record = try MeetingQuery.resolve(reference, in: libraryRows().map(\.record))
        return try get(record.id)
    }

    /// Use a separate read-only Store for searches so a long query cannot queue ahead
    /// of edits, progress writes or detail navigation on the app's writer actor.
    public func searchLibrary(_ query: String) throws -> Set<String> {
        let query = MeetingLibrary.normalizedQuery(query)
        let db = try database()
        var statement: OpaquePointer?
        try Task.checkCancellation()
        if query.isEmpty { return Set(try libraryItems().map(\.id)) }
        // Both sides use NFC. SQLite can reject literal non-candidates without allocating
        // Swift strings; Foundation still verifies canonical substring/grapheme semantics.
        guard sqlite3_prepare_v2(db, "SELECT id, search_text FROM meeting_library WHERE search_text IS NULL OR instr(search_text, ?) > 0", -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, query, Int32(query.utf8.count), transient)
        sqlite3_progress_handler(db, 100, { _ in
            var cancelled = false
            withUnsafeCurrentTask { cancelled = $0?.isCancelled ?? false }
            return cancelled ? 1 : 0
        }, nil)
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        var matches = Set<String>()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            try Task.checkCancellation()
            let id = String(cString: sqlite3_column_text(statement, 0))
            let text: String
            if let cached = sqlite3_column_text(statement, 1) {
                text = String(decoding: UnsafeBufferPointer(start: cached, count: Int(sqlite3_column_bytes(statement, 1))), as: UTF8.self)
            } else if let meeting = try? get(id) {
                // A legacy writer may have invalidated the cache since migration.
                text = MeetingLibrary.searchText(meeting)
            } else {
                step = sqlite3_step(statement)
                continue
            }
            if query.isEmpty || text.contains(query) { matches.insert(id) }
            step = sqlite3_step(statement)
        }
        try Task.checkCancellation()
        guard step == SQLITE_DONE else { throw StoreError.query(String(cString: sqlite3_errmsg(db))) }
        return matches
    }

    // MARK: - Meetings

    /// Interrupted work cannot survive a relaunch; make it visibly retryable.
    @discardableResult
    public func markInterruptedJobs() throws -> [Meeting] {
        var recovered: [Meeting] = []
        let interrupted = try documents("""
            SELECT m.data FROM meeting_library l JOIN meetings m ON m.id=l.id
            WHERE json_extract(l.data, '$.status') IN ('transcribing', 'summarizing')
            """).compactMap { try? decoder.decode(Meeting.self, from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
        for meeting in interrupted {
            recovered.append(try update(meeting.id) {
                $0.status = .error
                $0.stage = "Interrupted"
                $0.error = "The app stopped during processing. Your audio is safe; retry the operation."
            })
        }
        return recovered
    }

    public func list() throws -> [Meeting] {
        try documents("SELECT data FROM meetings")
            .compactMap { try? decoder.decode(Meeting.self, from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func get(_ id: String) throws -> Meeting {
        guard let row = try documents("SELECT data FROM meetings WHERE id=?", [id]).first else {
            throw StoreError.notFound
        }
        return try decoder.decode(Meeting.self, from: row)
    }

    public func exists(_ id: String) -> Bool {
        ((try? documents("SELECT data FROM meetings WHERE id=?", [id]))?.isEmpty == false)
    }

    @discardableResult
    public func insert(_ meeting: Meeting) throws -> Meeting {
        try execute("INSERT INTO meetings VALUES (?, ?)", [meeting.id, try encoded(meeting)])
        return meeting
    }

    /// Read-modify-write inside the actor so concurrent job progress and user edits
    /// interleave safely without one clobbering the other's fields.
    @discardableResult
    public func update(_ id: String, _ mutate: (inout Meeting) -> Void) throws -> Meeting {
        var meeting = try get(id)
        mutate(&meeting)
        meeting.updatedAt = Meeting.now()
        try execute("UPDATE meetings SET data=? WHERE id=?", [try encoded(meeting), id])
        return meeting
    }

    /// Move the authoritative document out of the live library in one transaction.
    /// Media stays in place until retention expires; readers and older builds see only live meetings.
    public func moveToRecentlyDeleted(_ id: String, now: Date = Date()) throws {
        guard !readOnly else { throw StoreError.readOnly }
        let db = try database()
        try Self.run(db, "BEGIN IMMEDIATE")
        do {
            let meeting = try get(id)
            guard !meeting.status.isBusy else { throw ValidationError("This meeting is processing.") }
            try execute("""
                INSERT INTO deleted_meetings (id, data, deleted_at, voiceprints)
                SELECT id, data, ?, (SELECT data FROM voiceprints WHERE meeting_id=meetings.id)
                FROM meetings WHERE id=?
                """, [String(now.timeIntervalSince1970), id])
            try delete(id)
            try Self.run(db, "COMMIT")
        } catch {
            try? Self.run(db, "ROLLBACK")
            throw error
        }
    }

    public func recentlyDeleted() throws -> [DeletedMeeting] {
        guard try hasTable("deleted_meetings") else { return [] }
        return try documents("""
            SELECT json_object('id', id, 'title', json_extract(data, '$.title'),
                               'deletedAt', deleted_at)
            FROM deleted_meetings ORDER BY deleted_at DESC
            """).map { try decoder.decode(DeletedMeeting.self, from: $0) }
    }

    @discardableResult
    public func restoreDeleted(_ id: String, now: Date = Date()) throws -> Meeting {
        guard !readOnly else { throw StoreError.readOnly }
        let db = try database()
        try Self.run(db, "BEGIN IMMEDIATE")
        do {
            guard let item = try recentlyDeleted().first(where: { $0.id == id }),
                  item.expiresAt > now,
                  let data = try documents("SELECT data FROM deleted_meetings WHERE id=?", [id]).first
            else { throw StoreError.notFound }
            var meeting = try decoder.decode(Meeting.self, from: data)
            // A category may have been removed during retention.
            if let categoryID = meeting.categoryID,
               !((try categories()).contains { $0.id == categoryID }) { meeting.categoryID = nil }
            try insert(meeting)
            try execute("""
                INSERT OR REPLACE INTO voiceprints (meeting_id, data)
                SELECT id, voiceprints FROM deleted_meetings WHERE id=? AND voiceprints IS NOT NULL
                """, [id])
            try execute("DELETE FROM deleted_meetings WHERE id=?", [id])
            try Self.run(db, "COMMIT")
            return meeting
        } catch {
            try? Self.run(db, "ROLLBACK")
            throw error
        }
    }

    /// Retry on a later cleanup if a media removal fails; never forget its archive record first.
    @discardableResult
    public func purgeExpiredDeleted(now: Date = Date()) throws -> [String] {
        guard !readOnly else { throw StoreError.readOnly }
        var purged: [String] = []
        for item in try recentlyDeleted() where item.expiresAt <= now {
            for url in [paths.audioURL(item.id), paths.videoURL(item.id)] {
                do { try FileManager.default.removeItem(at: url) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain
                    && error.code == NSFileNoSuchFileError { }
            }
            MediaFile.forget(item.id, paths: paths)
            try execute("DELETE FROM deleted_meetings WHERE id=?", [item.id])
            purged.append(item.id)
        }
        return purged
    }

    public func delete(_ id: String) throws {
        try execute("DELETE FROM meetings WHERE id=?", [id])
    }

    /// Compare the exact snapshot and replace all records in one transaction.
    public func replaceWithSplit(original: Meeting, parts: [Meeting]) throws {
        guard !readOnly else { throw StoreError.readOnly }
        let db = try database()
        try Self.run(db, "BEGIN IMMEDIATE")
        do {
            guard try get(original.id) == original, !original.status.isBusy else {
                throw ValidationError("This meeting changed during splitting. Retry with its latest content.")
            }
            guard parts.count >= 2 else { throw ValidationError("At least two parts are required.") }
            for part in parts { try insert(part) }
            try delete(original.id)
            try Self.run(db, "COMMIT")
        } catch {
            try? Self.run(db, "ROLLBACK")
            throw error
        }
    }

    private func encoded(_ meeting: Meeting) throws -> String {
        String(decoding: try encoder.encode(meeting), as: UTF8.self)
    }

    // MARK: - Speaker profiles

    /// One-time migration: preserve distinct identities even when names happen to match.
    public func migrateNamedSpeakers() throws {
        let db = try database()
        try Self.run(db, "CREATE TABLE IF NOT EXISTS migrations (id TEXT PRIMARY KEY)")
        try Self.run(db, "BEGIN IMMEDIATE")
        do {
            if try documents("SELECT id FROM migrations WHERE id='speaker_profiles_v1'").isEmpty {
                let ids = try documents("SELECT id FROM meetings").map { String(decoding: $0, as: UTF8.self) }
                for id in ids {
                    guard var meeting = try? get(id) else { continue }
                    var changed = false
                    for (speakerID, name) in meeting.speakers where meeting.speakerProfiles[speakerID] == nil {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, trimmed != speakerID,
                              trimmed.lowercased() != "unknown speaker",
                              trimmed.range(of: #"^speaker[ _]?[0-9]+$"#, options: [.regularExpression, .caseInsensitive]) == nil
                        else { continue }
                        let profile = try saveProfile(SpeakerProfile(name: trimmed))
                        meeting.speakerProfiles[speakerID] = profile.id
                        changed = true
                    }
                    if changed {
                        try execute("UPDATE meetings SET data=? WHERE id=?", [try encoded(meeting), meeting.id])
                    }
                }
                try execute("INSERT INTO migrations VALUES (?)", ["speaker_profiles_v1"])
            }
            try Self.run(db, "COMMIT")
        } catch {
            try? Self.run(db, "ROLLBACK")
            throw error
        }
    }

    /// Unlink all references and delete atomically without changing transcript snapshots.
    public func deleteProfile(_ id: String) throws -> [Meeting] {
        let db = try database()
        try Self.run(db, "BEGIN IMMEDIATE")
        do {
            var changed: [Meeting] = []
            for var meeting in try list() where meeting.speakerProfiles.values.contains(id) {
                meeting.speakerProfiles = meeting.speakerProfiles.filter { $0.value != id }
                let linked = meeting.speakerProfiles
                meeting.autoSpeakerProfiles = meeting.autoSpeakerProfiles.filter { linked[$0.key] != nil }
                try execute("UPDATE meetings SET data=? WHERE id=?", [try encoded(meeting), meeting.id])
                changed.append(meeting)
            }
            try execute("DELETE FROM speaker_profiles WHERE id=?", [id])
            try Self.run(db, "COMMIT")
            return changed
        } catch {
            try? Self.run(db, "ROLLBACK")
            throw error
        }
    }

    public func profiles() throws -> [SpeakerProfile] {
        try documents("SELECT data FROM speaker_profiles")
            .map { try decoder.decode(SpeakerProfile.self, from: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func saveProfile(_ profile: SpeakerProfile) throws -> SpeakerProfile {
        let profile = try profile.validated()
        try execute("INSERT OR REPLACE INTO speaker_profiles VALUES (?, ?)", [
            profile.id, String(decoding: try encoder.encode(profile), as: UTF8.self)
        ])
        return profile
    }

    /// Creates a profile and links it in one transaction, rolling back either on failure.
    public func createProfile(_ profile: SpeakerProfile, meetingID: String, speakerID: String) throws -> Meeting {
        let db = try database()
        try Self.run(db, "BEGIN IMMEDIATE")
        do {
            guard try !profiles().contains(where: { $0.id == profile.id }) else {
                throw ValidationError("This profile already exists.")
            }
            let saved = try saveProfile(profile)
            let meeting = try assignProfile(saved.id, meetingID: meetingID, speakerID: speakerID)
            try Self.run(db, "COMMIT")
            return meeting
        } catch {
            try? Self.run(db, "ROLLBACK")
            throw error
        }
    }

    public func assignProfile(_ profileID: String?, meetingID: String, speakerID: String,
                              localName: String? = nil) throws -> Meeting {
        let current = try get(meetingID)
        guard !current.status.isBusy else { throw ValidationError("Wait for this meeting to finish processing.") }
        guard current.speakers[speakerID] != nil else { throw ValidationError("This speaker no longer exists.") }
        var name = try localName.map { try Validation.speakerName($0) } ?? current.speakerName(speakerID)
        if let profileID {
            guard let profile = try profiles().first(where: { $0.id == profileID }) else {
                throw ValidationError("This speaker profile no longer exists.")
            }
            name = profile.name
        }
        return try update(meetingID) { meeting in
            meeting.speakerProfiles[speakerID] = profileID
            // A choice made by hand confirms or corrects a voice match.
            meeting.autoSpeakerProfiles[speakerID] = nil
            if meeting.speakerName(speakerID) != name {
                meeting.speakers[speakerID] = name
                Self.invalidateSummary(&meeting)
            }
        }
    }

    /// A summary names speakers, so a changed name makes it stale.
    private static func invalidateSummary(_ meeting: inout Meeting) {
        meeting.summary = nil
        let hasTranscript = !meeting.segments.isEmpty
        meeting.status = hasTranscript ? .transcribed : .ready
        meeting.error = nil
        meeting.progress = hasTranscript ? 100 : 0
        meeting.stage = hasTranscript ? "Transcript ready" : "Ready to transcribe"
    }

    // MARK: - Categories

    /// Categories in manual order. A read-only open of a library from before categories
    /// has no table, and so no categories.
    public func categories() throws -> [MeetingCategory] {
        guard try hasTable("categories") else { return [] }
        return MeetingCategory.sorted(
            try documents("SELECT data FROM categories").map { try decoder.decode(MeetingCategory.self, from: $0) },
            by: .manual
        )
    }

    @discardableResult
    public func saveCategory(_ category: MeetingCategory) throws -> MeetingCategory {
        var category = category
        category.name = try Validation.categoryName(category.name)
        try execute("INSERT OR REPLACE INTO categories VALUES (?, ?)", [
            category.id, String(decoding: try encoder.encode(category), as: UTF8.self)
        ])
        return category
    }

    /// Rewrites every category's manual position to match `ids`, in one transaction.
    /// Categories missing from `ids` keep their relative order after the listed ones.
    @discardableResult
    public func reorderCategories(_ ids: [String]) throws -> [MeetingCategory] {
        let db = try database()
        try Self.run(db, "BEGIN IMMEDIATE")
        do {
            let current = try categories()
            let listed = ids.compactMap { id in current.first { $0.id == id } }
            let ordered = listed + current.filter { !ids.contains($0.id) }
            var saved: [MeetingCategory] = []
            for (position, var category) in ordered.enumerated() {
                category.position = position
                saved.append(try saveCategory(category))
            }
            try Self.run(db, "COMMIT")
            return saved
        } catch {
            try? Self.run(db, "ROLLBACK")
            throw error
        }
    }

    /// Removes the category and clears it from its meetings atomically. Returns the meetings
    /// that changed so the caller can refresh them.
    public func deleteCategory(_ id: String) throws -> [Meeting] {
        let db = try database()
        try Self.run(db, "BEGIN IMMEDIATE")
        do {
            let ids = try documents(
                "SELECT id FROM meetings WHERE json_valid(data) AND json_extract(data, '$.category_id')=?", [id]
            ).map { String(decoding: $0, as: UTF8.self) }
            var changed: [Meeting] = []
            for meetingID in ids {
                var meeting = try get(meetingID)
                meeting.categoryID = nil
                try execute("UPDATE meetings SET data=? WHERE id=?", [try encoded(meeting), meeting.id])
                changed.append(meeting)
            }
            try execute("DELETE FROM categories WHERE id=?", [id])
            try Self.run(db, "COMMIT")
            return changed
        } catch {
            try? Self.run(db, "ROLLBACK")
            throw error
        }
    }

    // MARK: - Voice recognition

    /// Voiceprints are derived data, one row per meeting, and the learned rule is one row.
    /// A trigger removes a meeting's voiceprints when the meeting is deleted, including by an
    /// older build that does not know the table.
    private static func prepareVoiceTables(_ database: OpaquePointer) throws {
        try run(database, "CREATE TABLE IF NOT EXISTS voiceprints (meeting_id TEXT PRIMARY KEY, data TEXT NOT NULL)")
        try run(database, "CREATE TABLE IF NOT EXISTS voice_model (id INTEGER PRIMARY KEY, data TEXT NOT NULL)")
        try run(database, """
            CREATE TRIGGER IF NOT EXISTS voiceprints_after_meeting_delete AFTER DELETE ON meetings
            BEGIN DELETE FROM voiceprints WHERE meeting_id = OLD.id; END
            """)
    }

    /// A read-only open never creates tables, so a library from before voice recognition
    /// simply has no voices.
    private func hasTable(_ name: String) throws -> Bool {
        !(try documents("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [name]).isEmpty)
    }

    public func voiceprints(_ meetingID: String) throws -> MeetingVoiceprints? {
        guard try hasTable("voiceprints"),
              let row = try documents("SELECT data FROM voiceprints WHERE meeting_id=?", [meetingID]).first
        else { return nil }
        return try? decoder.decode(MeetingVoiceprints.self, from: row)
    }

    public func allVoiceprints() throws -> [MeetingVoiceprints] {
        guard try hasTable("voiceprints") else { return [] }
        return try documents("SELECT data FROM voiceprints").compactMap {
            try? decoder.decode(MeetingVoiceprints.self, from: $0)
        }
    }

    /// Stores a meeting's voiceprints only if the meeting still has the transcript they were
    /// computed from; otherwise they would describe labels that no longer exist.
    public func saveVoiceprints(_ prints: MeetingVoiceprints) throws {
        let meeting = try get(prints.meetingID)
        guard VoiceRecognition.fingerprint(of: meeting, modelRevision: prints.modelRevision) == prints.fingerprint else {
            throw ValidationError("This transcript changed while its voices were being read. Try again.")
        }
        try execute("INSERT OR REPLACE INTO voiceprints VALUES (?, ?)", [
            prints.meetingID, String(decoding: try encoder.encode(prints), as: UTF8.self),
        ])
    }

    /// Every manually linked voice whose voiceprint still matches its meeting's transcript and
    /// the current model. Returns how many meetings contributed.
    public func voiceSamples(modelRevision: String) throws -> (samples: [VoiceSample], meetings: Int) {
        var samples: [VoiceSample] = []
        var meetings = 0
        for prints in try allVoiceprints() where prints.modelRevision == modelRevision {
            guard let meeting = try? get(prints.meetingID),
                  VoiceRecognition.fingerprint(of: meeting, modelRevision: modelRevision) == prints.fingerprint
            else { continue }
            let found = VoiceSample.training(from: meeting, voiceprints: prints)
            if !found.isEmpty { meetings += 1 }
            samples += found
        }
        return (samples, meetings)
    }

    public func voiceModel() throws -> VoiceModel? {
        guard try hasTable("voice_model"), let row = try documents("SELECT data FROM voice_model WHERE id=1").first else {
            return nil
        }
        return try? decoder.decode(VoiceModel.self, from: row)
    }

    public func saveVoiceModel(_ model: VoiceModel) throws {
        try execute("INSERT OR REPLACE INTO voice_model VALUES (1, ?)", [
            String(decoding: try encoder.encode(model), as: UTF8.self),
        ])
    }

    /// Removes every voiceprint and the learned rule. Profile links, including ones made by
    /// voice, stay: they are the user's tags, not voice data.
    public func forgetVoices() throws {
        let db = try database()
        try Self.run(db, "BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM voiceprints", [])
            try execute("UPDATE deleted_meetings SET voiceprints=NULL", [])
            try execute("DELETE FROM voice_model", [])
            try Self.run(db, "COMMIT")
        } catch {
            try? Self.run(db, "ROLLBACK")
            throw error
        }
    }

    /// Links the confident matches in one write. Labels that gained a profile in the meantime
    /// keep it, and a transcript that changed since its voices were read is refused, since the
    /// matches would describe labels that no longer mean the same thing.
    public func applyVoiceMatches(
        _ matches: [VoiceMatch], meetingID: String, fingerprint: String, modelRevision: String
    ) throws -> (meeting: Meeting, applied: [VoiceMatch]) {
        let current = try get(meetingID)
        guard !current.status.isBusy else { throw ValidationError("Wait for this meeting to finish processing.") }
        guard VoiceRecognition.fingerprint(of: current, modelRevision: modelRevision) == fingerprint else {
            throw ValidationError("This transcript changed while its speakers were being recognized. Try again.")
        }
        let names = Dictionary(uniqueKeysWithValues: try profiles().map { ($0.id, $0.name) })
        let applicable = matches.filter { match in
            guard match.decision == .assigned, let profile = match.profileID else { return false }
            return names[profile] != nil && current.speakers[match.speaker] != nil
                && current.speakerProfiles[match.speaker] == nil
        }
        guard !applicable.isEmpty else { return (current, []) }
        let meeting = try update(meetingID) { meeting in
            var renamed = false
            for match in applicable {
                let profile = match.profileID!
                meeting.speakerProfiles[match.speaker] = profile
                meeting.autoSpeakerProfiles[match.speaker] = match.score ?? 0
                if meeting.speakerName(match.speaker) != names[profile]! {
                    meeting.speakers[match.speaker] = names[profile]!
                    renamed = true
                }
            }
            if renamed { Self.invalidateSummary(&meeting) }
        }
        return (meeting, applicable)
    }

    // MARK: - Settings

    public func settings() throws -> AppSettings {
        guard let row = try documents("SELECT data FROM settings WHERE id=1").first,
              let object = try? JSONSerialization.jsonObject(with: row) as? [String: Any]
        else {
            return AppSettings()
        }
        let (settings, changed) = AppSettings.migrating(from: object)
        if changed, !readOnly { try persist(settings) }
        return settings
    }

    @discardableResult
    public func saveSettings(_ settings: AppSettings) throws -> AppSettings {
        var settings = settings
        settings.transcription.hotWords = TranscriptionSettings.normalizeHotWords(settings.transcription.hotWords)
        if settings.summary.model.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.summary.model = settings.summary.provider.defaultModel
        }
        try persist(settings)
        return settings
    }

    private func persist(_ settings: AppSettings) throws {
        try execute(
            "INSERT OR REPLACE INTO settings VALUES (1, ?)",
            [String(decoding: try encoder.encode(settings), as: UTF8.self)]
        )
    }
}
