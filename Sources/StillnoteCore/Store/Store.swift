import Foundation
import SQLite3

public enum StoreError: LocalizedError {
    case open(String)
    case query(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .open(let detail): return "Could not open the local database: \(detail)"
        case .query(let detail): return "The local database rejected a change: \(detail)"
        case .notFound: return "Meeting not found."
        }
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Local SQLite store. Meetings and settings retain the legacy JSON document schema;
/// reusable speaker profiles live in an additional table.
public actor Store {
    public let paths: Paths
    private var handle: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(paths: Paths) throws {
        self.paths = paths
        try paths.createDirectories()
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            paths.databaseURL.path, &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK, let database else {
            throw StoreError.open(String(cString: sqlite3_errmsg(database)))
        }
        handle = database
        sqlite3_busy_timeout(database, 30_000)
        try Store.run(database, "PRAGMA journal_mode=WAL")
        try Store.run(database, "CREATE TABLE IF NOT EXISTS meetings (id TEXT PRIMARY KEY, data TEXT NOT NULL)")
        try Store.run(database, "CREATE TABLE IF NOT EXISTS speaker_profiles (id TEXT PRIMARY KEY, data TEXT NOT NULL)")
        try Store.run(database, "CREATE TABLE IF NOT EXISTS settings (id INTEGER PRIMARY KEY, data TEXT NOT NULL)")
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
        let database = try self.database()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.query(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.query(String(cString: sqlite3_errmsg(database)))
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
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        var rows: [Data] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                rows.append(Data(String(cString: text).utf8))
            }
        }
        return rows
    }

    // MARK: - Meetings

    /// Interrupted work cannot survive a relaunch; make it visibly retryable.
    @discardableResult
    public func markInterruptedJobs() throws -> [Meeting] {
        var recovered: [Meeting] = []
        for meeting in try list() where meeting.status.isBusy {
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

    public func delete(_ id: String) throws {
        try execute("DELETE FROM meetings WHERE id=?", [id])
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
                for var meeting in try list() {
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
            if meeting.speakerName(speakerID) != name {
                meeting.speakers[speakerID] = name
                meeting.summary = nil
                let hasTranscript = !meeting.segments.isEmpty
                meeting.status = hasTranscript ? .transcribed : .ready
                meeting.error = nil
                meeting.progress = hasTranscript ? 100 : 0
                meeting.stage = hasTranscript ? "Transcript ready" : "Ready to transcribe"
            }
        }
    }

    // MARK: - Settings

    public func settings() throws -> AppSettings {
        guard let row = try documents("SELECT data FROM settings WHERE id=1").first,
              let object = try? JSONSerialization.jsonObject(with: row) as? [String: Any]
        else {
            return AppSettings()
        }
        let (settings, changed) = AppSettings.migrating(from: object)
        if changed { try persist(settings) }
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
