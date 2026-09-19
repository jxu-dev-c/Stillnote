import Foundation
import Testing

@testable import StillnoteCore

func temporaryPaths() throws -> Paths {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("stillnote-tests-\(UUID().uuidString)", isDirectory: true)
    let paths = Paths(
        dataDirectory: root.appendingPathComponent("data"),
        modelDirectory: root.appendingPathComponent("models")
    )
    try paths.createDirectories()
    return paths
}

@Suite struct StoreTests {
    @Test func createsReadsAndUpdatesMeetings() async throws {
        let paths = try temporaryPaths()
        let store = try Store(paths: paths)
        let meeting = Meeting(
            id: "abc", title: "Weekly sync", audioName: "recording.wav", language: "auto",
            speakerCount: nil, duration: 12.5
        )
        try await store.insert(meeting)

        let loaded = try await store.get("abc")
        #expect(loaded.title == "Weekly sync")
        #expect(loaded.status == .ready)
        #expect(loaded.audioURL == "/api/meetings/abc/audio")
        #expect(loaded.videoURL == nil)

        let updated = try await store.update("abc") { $0.status = .transcribed; $0.notes = "hello" }
        #expect(updated.notes == "hello")
        #expect(try await store.list().count == 1)

        try await store.delete("abc")
        #expect(try await store.list().isEmpty)
    }

    /// Interrupted work must come back visibly retryable rather than stuck in progress.
    @Test func marksInterruptedJobsAsRetryable() async throws {
        let paths = try temporaryPaths()
        let store = try Store(paths: paths)
        try await store.insert(
            Meeting(id: "busy", title: "In flight", audioName: "a", language: "auto",
                    speakerCount: nil, duration: 1)
        )
        _ = try await store.update("busy") { $0.status = .transcribing }

        let reopened = try Store(paths: paths)
        let recovered = try await reopened.markInterruptedJobs()
        #expect(recovered.count == 1)
        #expect(try await reopened.get("busy").status == .error)
        #expect(try await reopened.get("busy").stage == "Interrupted")
    }

    /// A document written by the Python app, predating fields added later, still loads.
    @Test func readsLegacyDocumentsWrittenByThePythonApp() async throws {
        let paths = try temporaryPaths()
        _ = try Store(paths: paths)
        let legacy = """
            {"id":"old","title":"Legacy","created_at":"2025-01-01T00:00:00+00:00",
             "updated_at":"2025-01-01T00:00:00+00:00","duration":30.0,"status":"transcribed",
             "progress":100,"stage":"Transcript ready","error":null,"audio_name":"a.webm",
             "audio_url":"/api/meetings/old/audio","language":"en","speaker_count":2,
             "speakers":{"speaker_1":"Ada"},
             "segments":[{"id":"segment_1","start":0.0,"end":1.0,"speaker":"speaker_1","text":"hi"}],
             "summary":null,"notes":""}
            """
        try runSQL(paths.databaseURL, "INSERT OR REPLACE INTO meetings VALUES ('old', '\(escaped(legacy))')")

        let reopened = try Store(paths: paths)
        let meeting = try await reopened.get("old")
        #expect(meeting.speakerProfiles.isEmpty)
        #expect(meeting.contextLinks.isEmpty)
        #expect(meeting.videoURL == nil)
        #expect(meeting.summaryIncludeVideoPath == false)
        #expect(meeting.segments.first?.text == "hi")
        #expect(meeting.speakerName("speaker_1") == "Ada")
    }

    @Test func migratesRetiredSettings() async throws {
        let paths = try temporaryPaths()
        _ = try Store(paths: paths)
        let retired = """
            {"transcription":{"model":"vibevoice-7b","language":"en","speaker_count":3},
             "summary":{"provider":"anthropic","model":"claude-3","api_key":"secret",
             "base_url":"https://example.com","reasoning_effort":"low"}}
            """
        try runSQL(paths.databaseURL, "INSERT OR REPLACE INTO settings VALUES (1, '\(escaped(retired))')")

        let store = try Store(paths: paths)
        let settings = try await store.settings()
        #expect(settings.transcription.model == SpeechCatalog.defaultModel)
        #expect(settings.transcription.language == "en")
        #expect(settings.transcription.speakerCount == 3)
        #expect(settings.summary.provider == .claudeCode)
        #expect(settings.summary.model == SummaryProvider.claudeCode.defaultModel)
        #expect(settings.summary.reasoningEffort == .high)

        // The credential fields are dropped from the stored record, not just the struct.
        let stored = try readSQL(paths.databaseURL, "SELECT data FROM settings WHERE id=1")
        #expect(!stored.contains("secret"))
        #expect(!stored.contains("base_url"))
    }

    @Test func switchingProviderKeepsAModelName() async throws {
        let paths = try temporaryPaths()
        let store = try Store(paths: paths)
        var settings = AppSettings()
        settings.summary = SummarySettings(provider: .claudeCode, model: "", reasoningEffort: .medium)
        let saved = try await store.saveSettings(settings)
        #expect(saved.summary.model == SummaryProvider.claudeCode.defaultModel)
    }
}

private func escaped(_ json: String) -> String { json.replacingOccurrences(of: "'", with: "''") }

private func runSQL(_ database: URL, _ sql: String) throws {
    _ = try readSQL(database, sql)
}

private func readSQL(_ database: URL, _ sql: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [database.path, sql]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
