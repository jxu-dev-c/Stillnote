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
    /// The `stillnote` CLI opens the library read-only when the app is closed. That must never
    /// create an empty database at a mistaken path, and must never accept a write.
    @Test func readOnlyOpenNeitherCreatesNorWrites() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }

        #expect(throws: StoreError.self) { try Store(paths: paths, readOnly: true) }
        #expect(!FileManager.default.fileExists(atPath: paths.databaseURL.path))

        let writable = try Store(paths: paths)
        let meeting = Meeting(
            id: "m1", title: "Kept", audioName: "a.wav", language: "en", speakerCount: nil, duration: 1
        )
        try await writable.insert(meeting)

        let reader = try Store(paths: paths, readOnly: true)
        #expect(reader.readOnly)
        #expect(try await reader.list().map(\.id) == ["m1"])
        #expect(try await reader.get("m1").title == "Kept")
        await #expect(throws: StoreError.self) { try await reader.update("m1") { $0.title = "Changed" } }
        await #expect(throws: StoreError.self) { try await reader.delete("m1") }
        // Reading settings migrates in place on a writable handle; on this one it must not try.
        #expect(try await reader.settings() == AppSettings())
        #expect(try await writable.get("m1").title == "Kept")
    }

    /// `standard()` can move a checkout's data into Application Support. `resolve()` is the
    /// same path arithmetic with none of that, which is what the CLI needs.
    @Test func resolveAppliesOverridesWithoutTouchingTheFilesystem() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stillnote-resolve-\(UUID().uuidString)", isDirectory: true)
        let paths = Paths.resolve(environment: [
            "STILLNOTE_DATA_DIR": root.appendingPathComponent("data").path,
            "STILLNOTE_MODEL_DIR": root.appendingPathComponent("models").path,
        ])
        #expect(paths.dataDirectory.lastPathComponent == "data")
        #expect(paths.modelDirectory.lastPathComponent == "models")
        #expect(paths.commandSocketURL == paths.dataDirectory.appendingPathComponent("cli.sock"))
        #expect(!FileManager.default.fileExists(atPath: root.path))

        let defaults = Paths.resolve(environment: [:])
        #expect(defaults.dataDirectory.path.hasSuffix("Application Support/Stillnote/data"))
        #expect(defaults.commandSocketURL.path.hasSuffix("Stillnote/data/cli.sock"))
        // The default socket path has to fit sockaddr_un on a normal home directory.
        #expect(defaults.commandSocketURL.path.utf8.count <= CommandSocket.maximumPathLength)
    }

    /// Older settings rows carry no `cli` block; the command interface defaults to on.
    @Test func commandInterfaceSettingDefaultsOnAndPersistsOff() async throws {
        #expect(AppSettings().cli.enabled)
        #expect(AppSettings.migrating(from: [:]).settings.cli.enabled)
        #expect(AppSettings.migrating(from: ["cli": ["enabled": false]]).settings.cli.enabled == false)
        let legacy = Data(#"{"transcription":{"model":"moss-0.9b","language":"auto"},"summary":{"provider":"codex","model":"m","reasoning_effort":"high"}}"#.utf8)
        #expect(try JSONDecoder().decode(AppSettings.self, from: legacy).cli.enabled)

        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        try await store.saveSettings(AppSettings(cli: CLISettings(enabled: false)))
        #expect(try await Store(paths: paths).settings().cli.enabled == false)
    }

    @Test func permissionBypassDefaultsOnAndPersistsOff() async throws {
        let legacy = Data(#"{"provider":"codex","model":"custom","reasoning_effort":"low"}"#.utf8)
        #expect(try JSONDecoder().decode(SummarySettings.self, from: legacy).bypassPermissions)
        #expect(SummarySettings().bypassPermissions)
        #expect(AppSettings.migrating(from: [:]).settings.summary.bypassPermissions)
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        let settings = AppSettings(summary: SummarySettings(bypassPermissions: false))
        try await store.saveSettings(settings)
        let reopened = try Store(paths: paths)
        #expect(try await reopened.settings() == settings)
    }

    @Test func summaryPromptDefaultsAndCodableCompatibility() throws {
        let legacy = Data(#"{"provider":"codex","model":"custom","reasoning_effort":"low"}"#.utf8)
        let decoded = try JSONDecoder().decode(SummarySettings.self, from: legacy)
        #expect(decoded.agentPrompt == Summarizer.defaultAgentPrompt)
        #expect(SummarySettings().agentPrompt == Summarizer.defaultAgentPrompt)
        #expect(SummarySettings(agentPrompt: " \n\t").resolvedAgentPrompt == Summarizer.defaultAgentPrompt)
        let custom = SummarySettings(agentPrompt: "Custom instructions\nKeep formatting.")
        let data = try JSONEncoder().encode(custom)
        #expect(try JSONDecoder().decode(SummarySettings.self, from: data) == custom)
        #expect(String(decoding: data, as: UTF8.self).contains("agent_prompt"))
    }

    @Test func persistsPromptAcrossReloadAndProviderChanges() async throws {
        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let store = try Store(paths: paths)
        var settings = AppSettings()
        settings.summary.agentPrompt = "Focus on decisions."
        try await store.saveSettings(settings)
        let reopened = try Store(paths: paths)
        settings = try await reopened.settings()
        #expect(settings.summary.agentPrompt == "Focus on decisions.")
        settings.summary.provider = .claudeCode
        settings.summary.model = "custom"
        settings.summary.reasoningEffort = .low
        try await reopened.saveSettings(settings)
        #expect(try await store.settings().summary.agentPrompt == "Focus on decisions.")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        let migrated = AppSettings.migrating(from: object)
        #expect(!migrated.changed)
        #expect(migrated.settings == settings)
    }

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
        #expect(settings.summary.agentPrompt == Summarizer.defaultAgentPrompt)

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
