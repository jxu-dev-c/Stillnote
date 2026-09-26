import Foundation
import Testing

@testable import StillnoteCore

/// Exercises the commands the CLI answers on its own when the app is closed, against a real
/// store, so the read-only path is covered end to end rather than only its pieces.
@Suite struct CommandRunnerTests {
    private func library() async throws -> (Store, Paths) {
        let paths = try temporaryPaths()
        let store = try Store(paths: paths)
        var launch = Meeting(
            id: "aa11bb22", title: "Product launch planning", audioName: "a.wav", language: "en",
            speakerCount: 2, duration: 600
        )
        launch.createdAt = "2026-09-08T15:04:05.100+00:00"
        launch.updatedAt = launch.createdAt
        launch.speakers = ["speaker_1": "Jackson", "speaker_2": "Priya"]
        launch.segments = [
            Segment(id: "s0", start: 0, end: 9, speaker: "speaker_1",
                    text: "The ANE work blocks the Sept launch."),
            Segment(id: "s1", start: 10, end: 19, speaker: "speaker_2",
                    text: "We decided to ship the ANE adapter only."),
        ]
        launch.summary = MeetingSummary(
            overview: "Sept launch ships with the ANE adapter only.", keyPoints: ["ANE was the blocker"],
            decisions: ["Ship in Sept"], actionItems: [ActionItem(text: "Land ANE", owner: "Jackson")],
            provider: "codex", model: "gpt-5-codex", generatedAt: "2026-09-08T16:00:00.000+00:00"
        )
        launch.notes = "Ping Jackson about ANE coverage."
        launch.status = .complete
        launch.progress = 100

        var sync = Meeting(
            id: "cc33dd44", title: "Weekly sync", audioName: "b.wav", language: "en", speakerCount: 1,
            duration: 120
        )
        sync.createdAt = "2026-05-14T10:00:00.000+00:00"
        sync.updatedAt = sync.createdAt
        sync.speakers = ["speaker_1": "Jackson"]
        sync.segments = [Segment(id: "s0", start: 0, end: 9, speaker: "speaker_1", text: "ANE throughput.")]
        sync.status = .transcribed

        try await store.insert(launch)
        try await store.insert(sync)
        return (store, paths)
    }

    private func run(_ argv: [String], _ store: Store) async throws -> CLIResponse {
        let invocation = try CommandCatalog.parse(argv)
        guard let response = try await CommandRunner.read(invocation.request, store: store) else {
            Issue.record("'\(invocation.spec.name)' should be answerable without the app")
            return CLIResponse(code: .failed, message: "not a read command")
        }
        return response
    }

    @Test func listsMeetingsNewestFirst() async throws {
        let (store, paths) = try await library()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let payload = try await run(["list"], store).payload?.decoded(ListPayload.self)
        #expect(payload?.count == 2)
        #expect(payload?.meetings.map(\.id) == ["aa11bb22", "cc33dd44"])
        #expect(payload?.meetings.first?.speakers == ["Jackson", "Priya"])
        #expect(payload?.meetings.first?.hasSummary == true)
        #expect(payload?.meetings.last?.hasSummary == false)
    }

    @Test func showOmitsTheTranscriptUnlessAsked() async throws {
        let (store, paths) = try await library()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let plain = try await run(["show", "latest"], store).payload?.decoded(MeetingPayload.self)
        #expect(plain?.segments == nil)
        #expect(plain?.segmentCount == 2)
        let full = try await run(["show", "aa11", "--segments"], store).payload?
            .decoded(MeetingPayload.self)
        #expect(full?.segments?.count == 2)
        #expect(full?.segments?.first?.speakerName == "Jackson")
    }

    @Test func showCanNarrowTheTranscriptToOneSpeaker() async throws {
        let (store, paths) = try await library()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let payload = try await run(["show", "aa11", "--segments", "--speaker", "Priya"], store)
            .payload?.decoded(MeetingPayload.self)
        #expect(payload?.segments?.map(\.id) == ["s1"])
        // The speaker table is unaffected by the filter.
        #expect(payload?.speakers.count == 2)
    }

    /// The shape of "all my conversations with Jackson back in May".
    @Test func listCombinesAMonthAndASpeaker() async throws {
        let (store, paths) = try await library()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let payload = try await run(
            ["list", "--since", "2026-05", "--until", "2026-05", "--speaker", "Jackson"], store
        ).payload?.decoded(ListPayload.self)
        #expect(payload?.meetings.map(\.id) == ["cc33dd44"])
    }

    @Test func searchesAcrossFieldsAndReportsWhereItMatched() async throws {
        let (store, paths) = try await library()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let payload = try await run(["search", "ANE"], store).payload?.decoded(SearchPayload.self)
        #expect(payload?.count == 2)
        let first = payload?.results.first
        #expect(first?.id == "aa11bb22")
        #expect(Set(first?.hits.map(\.field) ?? []) == [.transcript, .summary, .notes])
        let scoped = try await run(["search", "ANE", "--in", "notes"], store).payload?
            .decoded(SearchPayload.self)
        #expect(scoped?.count == 1)
        #expect(scoped?.results.first?.hits.allSatisfy { $0.field == .notes } == true)
    }

    @Test func exportsToStdoutAndToAFile() async throws {
        let (store, paths) = try await library()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let inline = try await run(["export", "aa11", "--format", "srt"], store)
        #expect(inline.message.contains("00:00:00,000 --> 00:00:09,000"))
        #expect(try inline.payload?.decoded(ExportPayload.self).path == nil)

        let destination = paths.dataDirectory.appendingPathComponent("out.md")
        let written = try await run(
            ["export", "aa11", "--format", "md", "--out", destination.path], store
        )
        #expect(written.isSuccess)
        let text = try String(contentsOf: destination, encoding: .utf8)
        #expect(text.hasPrefix("# Product launch planning"))
        #expect(try written.payload?.decoded(ExportPayload.self).path == destination.path)
    }

    /// Given a directory, export picks the filename the app would have suggested.
    @Test func exportIntoADirectoryNamesTheFileItself() async throws {
        let (store, paths) = try await library()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let response = try await run(["export", "aa11", "--out", paths.dataDirectory.path], store)
        let written = try response.payload?.decoded(ExportPayload.self).path
        #expect(written?.hasSuffix("Product launch planning.md") == true)
    }

    @Test func summaryAndNotesRead() async throws {
        let (store, paths) = try await library()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        #expect(try await run(["summary", "show", "aa11"], store).message.contains("ANE adapter only"))
        #expect(try await run(["notes", "show", "aa11"], store).message == "Ping Jackson about ANE coverage.")
        #expect(try await run(["summary", "show", "cc33"], store).message.contains("no summary yet"))
        #expect(try await run(["notes", "show", "cc33"], store).message.contains("no notes"))
    }

    @Test func reportsBadReferencesAndBadOptionsAsItsOwnCodes() async throws {
        let (store, paths) = try await library()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        await #expect(throws: CLIError.self) { try await run(["show", "zzzz"], store) }
        await #expect(throws: CLIError.self) { try await run(["export", "aa11", "--format", "pdf"], store) }
        await #expect(throws: CLIError.self) { try await run(["list", "--status", "nonsense"], store) }
        await #expect(throws: CLIError.self) { try await run(["list", "--since", "May"], store) }
        await #expect(throws: CLIError.self) { try await run(["list", "--limit", "0"], store) }
    }

    /// Commands that write or record are not answerable here; the CLI turns that into advice to
    /// open the app rather than attempting a second writer.
    @Test func writeCommandsAreNotServedByTheReadPath() async throws {
        let (store, paths) = try await library()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        for argv in [
            ["transcript", "replace", "ANE", "AEM", "--all"],
            ["record", "start"],
            ["summarize", "aa11", "--allow-remote"],
            ["notes", "set", "aa11", "--text", "x"],
        ] {
            let invocation = try CommandCatalog.parse(argv)
            #expect(invocation.spec.requiresApp, "\(invocation.spec.name) must require the app")
            #expect(try await CommandRunner.read(invocation.request, store: store) == nil)
        }
    }

    /// Every read-only command in the catalog really is served by the read path, so the CLI's
    /// offline fallback can never advertise something it then refuses.
    @Test func everyOfflineCommandIsActuallyServed() async throws {
        let (store, paths) = try await library()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        for spec in CommandCatalog.commands where !spec.requiresApp {
            // `status` is the one read command the CLI answers itself, from the paths it resolved.
            guard spec.path != ["status"] else { continue }
            let argv = spec.path + spec.positionals.compactMap { name in
                name.hasSuffix("?") ? nil : (name == "query" ? "ANE" : "latest")
            }
            let invocation = try CommandCatalog.parse(argv)
            let response = try await CommandRunner.read(invocation.request, store: store)
            #expect(response != nil, "'\(spec.name)' claims to work offline but is not served")
        }
    }

    @Test func offlineStatusNamesTheLibraryAndSocket() throws {
        let paths = Paths.resolve(environment: ["STILLNOTE_DATA_DIR": "/tmp/sn-status"])
        let payload = try CommandRunner.offlineStatus(paths: paths, meetings: 7).payload?
            .decoded(StatusPayload.self)
        #expect(payload?.running == false)
        #expect(payload?.meetings == 7)
        #expect(payload?.dataDirectory == "/tmp/sn-status")
        #expect(payload?.socket == "/tmp/sn-status/cli.sock")
    }

    @Test func replaceResponseSpellsOutTheDryRunAndTheInvalidation() throws {
        let changes = [ReplaceChange(id: "aa11bb22", title: "Launch", outcome: ReplaceOutcome(matches: 3, segments: 2))]
        let dry = try CommandRunner.replaceResponse(ReplacePayload(
            find: "ANE", replacement: "AEM", dryRun: true, changes: changes, summaryInvalidated: true
        ))
        #expect(dry.message.contains("Dry run"))
        #expect(dry.message.contains("Nothing was written"))
        #expect(try dry.payload?.decoded(ReplacePayload.self).matches == 3)

        let applied = try CommandRunner.replaceResponse(ReplacePayload(
            find: "ANE", replacement: "AEM", dryRun: false, changes: changes, summaryInvalidated: true
        ))
        #expect(applied.message.contains("summarize"))
        #expect(!applied.message.contains("Dry run"))

        let nothing = try CommandRunner.replaceResponse(ReplacePayload(
            find: "ANE", replacement: "AEM", dryRun: false, changes: [], summaryInvalidated: false
        ))
        #expect(nothing.message.contains("Nothing changed"))
        #expect(try nothing.payload?.decoded(ReplacePayload.self).matches == 0)
    }

    @Test func helpDescribesEveryCommandAndOneCommand() throws {
        let all = CommandRunner.help(CLIRequest(command: ["help"]))
        #expect(try all.payload?.decoded(HelpPayload.self).commands.count == CommandCatalog.commands.count)
        for spec in CommandCatalog.commands { #expect(all.message.contains(spec.name)) }

        let one = CommandRunner.help(CLIRequest(command: ["help"], positionals: ["transcript replace"]))
        #expect(one.message.contains("--dry-run"))
        #expect(try one.payload?.decoded(HelpPayload.self).commands.count == 1)
    }
}
