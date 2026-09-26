import Foundation

/// Builds every response the CLI can print, so the app over the socket and the CLI's own
/// read-only path render identically. Human-readable text is the response `message`; `--json`
/// prints the payload.
public enum CommandRunner {
    // MARK: - Read commands

    /// Handles the commands that only read. Returns nil for anything that needs the app.
    ///
    /// The same code serves both transports: the app calls it with its live store, and the CLI
    /// calls it with a read-only handle when the app is closed.
    public static func read(_ request: CLIRequest, store: Store) async throws -> CLIResponse? {
        switch request.command {
        case ["help"]:
            return help(request)
        case ["list"]:
            return try await list(request, store: store)
        case ["show"]:
            return try await show(request, store: store)
        case ["search"]:
            return try await search(request, store: store)
        case ["export"]:
            return try await export(request, store: store)
        case ["summary", "show"]:
            return try await summaryShow(request, store: store)
        case ["notes", "show"]:
            return try await notesShow(request, store: store)
        default:
            return nil
        }
    }

    public static func help(_ request: CLIRequest) -> CLIResponse {
        let requested = request.positionals.first
        let commands = requested.flatMap { name in
            CommandCatalog.commands.filter { $0.name == name || $0.path.first == name }
        } ?? CommandCatalog.commands
        return CLIResponse(
            code: .ok,
            message: CommandCatalog.help(command: requested),
            payload: try? CLIJSON(HelpPayload(commands: commands.isEmpty ? CommandCatalog.commands : commands))
        )
    }

    static func filter(_ request: CLIRequest) throws -> MeetingFilter {
        var filter = MeetingFilter()
        if let since = request.value("since") { filter.since = try MeetingQuery.range(since).start }
        if let until = request.value("until") { filter.until = try MeetingQuery.range(until).end }
        if let raw = request.value("status") {
            guard let status = MeetingStatus(rawValue: raw.lowercased()) else {
                let known = ["ready", "transcribing", "transcribed", "summarizing", "complete", "error"]
                throw CLIError.usage("Unknown status '\(raw)'. Use one of: \(known.joined(separator: ", ")).")
            }
            filter.status = status
        }
        filter.speaker = request.value("speaker")
        if let limit = try request.integer("limit") {
            guard limit > 0 else { throw CLIError.usage("--limit needs a positive number.") }
            filter.limit = limit
        }
        return filter
    }

    static func list(_ request: CLIRequest, store: Store) async throws -> CLIResponse {
        var filter = try filter(request)
        if filter.limit == nil { filter.limit = 50 }
        let meetings = MeetingQuery.filter(try await store.list(), filter)
        let digests = meetings.map(MeetingDigest.init)
        var lines: [String]
        if digests.isEmpty {
            lines = ["No meetings match."]
        } else {
            lines = digests.map { digest in
                let speakers = digest.speakers.isEmpty ? "no speakers yet" : digest.speakers.joined(separator: ", ")
                return "\(digest.id)  \(digest.createdAt.prefix(10))  "
                    + "\(Formatting.duration(digest.duration).padding(toLength: 8, withPad: " ", startingAt: 0))"
                    + "\(digest.status.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0))"
                    + "\(digest.title) — \(speakers)"
            }
            lines.append("")
            lines.append("\(digests.count) meeting(s).")
        }
        return try .success(lines.joined(separator: "\n"), ListPayload(digests))
    }

    static func meeting(_ request: CLIRequest, store: Store) async throws -> Meeting {
        guard let reference = request.positionals.first else {
            throw CLIError.usage("Name a meeting, or use 'latest'.")
        }
        return try MeetingQuery.resolve(reference, in: try await store.list())
    }

    static func show(_ request: CLIRequest, store: Store) async throws -> CLIResponse {
        let meeting = try await meeting(request, store: store)
        let payload = MeetingPayload(
            meeting, includeSegments: request.has("segments"), speakerFilter: request.value("speaker")
        )
        return try .success(render(payload), payload)
    }

    public static func render(_ payload: MeetingPayload) -> String {
        var lines = [
            payload.title,
            "\(payload.id)  \(payload.createdAt)  \(Formatting.duration(payload.duration))  \(payload.status.rawValue)",
        ]
        if let error = payload.error { lines.append("Error: \(error)") }
        let speakers = payload.speakers.map { $0.profile ? "\($0.name) [\($0.id), profile]" : "\($0.name) [\($0.id)]" }
        lines.append("Speakers: \(speakers.isEmpty ? "none yet" : speakers.joined(separator: ", "))")
        lines.append("Transcript: \(payload.segmentCount) segment(s)")
        if let cleanup = payload.cleanup, cleanup.removedDuration > 0 {
            lines.append(
                "Silence trimmed: \(Formatting.duration(cleanup.head)) head, "
                    + "\(Formatting.duration(cleanup.tail)) tail"
            )
        }
        if let summary = payload.summary {
            lines += ["", "Summary (\(summary.provider), \(summary.model)):", summary.overview]
            if !summary.keyPoints.isEmpty {
                lines += ["", "Key points:"] + summary.keyPoints.map { "  - \($0)" }
            }
            if !summary.decisions.isEmpty {
                lines += ["", "Decisions:"] + summary.decisions.map { "  - \($0)" }
            }
            if !summary.actionItems.isEmpty {
                lines += ["", "Action items:"] + summary.actionItems.map { item in
                    var text = "  - \(item.text)"
                    if let owner = item.owner { text += " (owner: \(owner))" }
                    if let due = item.due { text += " (due: \(due))" }
                    return text
                }
            }
        } else {
            lines += ["", "No summary yet."]
        }
        if !payload.notes.isEmpty { lines += ["", "Notes:", payload.notes] }
        if !payload.contextLinks.isEmpty {
            lines += ["", "Links:"] + payload.contextLinks.map {
                "  - \($0.title.isEmpty ? $0.url : "\($0.title): \($0.url)")"
            }
        }
        if let segments = payload.segments {
            lines += ["", "Transcript:"]
            lines += segments.map { "[\(Formatting.timestamp($0.start))] \($0.speakerName): \($0.text)" }
            if segments.isEmpty { lines.append("  (nothing matched)") }
        }
        return lines.joined(separator: "\n")
    }

    static func search(_ request: CLIRequest, store: Store) async throws -> CLIResponse {
        guard let query = request.positionals.first else { throw CLIError.usage("Give something to search for.") }
        var filter = try filter(request)
        if filter.limit == nil { filter.limit = 20 }
        let context = try request.integer("context") ?? 80
        let results = try MeetingQuery.search(
            try await store.list(), query: query, fields: try MeetingQuery.fields(request.value("in")),
            filter: filter, context: context
        )
        var lines: [String]
        if results.isEmpty {
            lines = ["Nothing matched '\(query)'."]
        } else {
            lines = []
            for result in results {
                lines.append("\(result.title) — \(result.createdAt.prefix(10)) — \(result.id)")
                lines.append("  \(result.matches) match(es); speakers: \(result.speakers.joined(separator: ", "))")
                for hit in result.hits.prefix(8) {
                    let where_ = hit.start.map { "[\(Formatting.timestamp($0))]" } ?? "[\(hit.field.rawValue)]"
                    let who = hit.speaker.map { "\($0): " } ?? ""
                    lines.append("  \(where_) \(who)\(hit.snippet)")
                }
                if result.hits.count > 8 { lines.append("  … \(result.hits.count - 8) more in this meeting") }
                lines.append("")
            }
            lines.append("\(results.count) meeting(s) matched.")
        }
        return try .success(lines.joined(separator: "\n"), SearchPayload(query: query, results: results))
    }

    static func export(_ request: CLIRequest, store: Store) async throws -> CLIResponse {
        let meeting = try await meeting(request, store: store)
        let raw = request.value("format") ?? ExportFormat.markdown.rawValue
        guard let format = ExportFormat(rawValue: raw.lowercased()) else {
            let known = ExportFormat.allCases.map(\.rawValue).joined(separator: ", ")
            throw CLIError.usage("Unknown format '\(raw)'. Use one of: \(known).")
        }
        let text = Exporter.text(meeting, format: format)
        guard let out = request.value("out") else {
            return try .success(text, ExportPayload(id: meeting.id, format: format, path: nil, text: text))
        }
        var destination = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            destination.appendPathComponent(Exporter.suggestedFilename(meeting, format: format))
        }
        do {
            try Data(text.utf8).write(to: destination, options: .atomic)
        } catch {
            throw CLIError.failed("Could not write \(destination.path): \(error.localizedDescription)")
        }
        return try .success(
            "Exported \(meeting.title) to \(destination.path)",
            ExportPayload(id: meeting.id, format: format, path: destination.path, text: nil)
        )
    }

    static func summaryShow(_ request: CLIRequest, store: Store) async throws -> CLIResponse {
        let meeting = try await meeting(request, store: store)
        guard let summary = meeting.summary else {
            return CLIResponse(
                code: .ok, message: "\(meeting.title) has no summary yet.",
                payload: try CLIJSON(MeetingPayload(meeting, includeSegments: false))
            )
        }
        var payload = MeetingPayload(meeting, includeSegments: false)
        payload.summary = summary
        return try .success(render(payload), payload)
    }

    static func notesShow(_ request: CLIRequest, store: Store) async throws -> CLIResponse {
        let meeting = try await meeting(request, store: store)
        return try .success(
            meeting.notes.isEmpty ? "\(meeting.title) has no notes." : meeting.notes,
            TextPayload(id: meeting.id, text: meeting.notes)
        )
    }

    // MARK: - Shared response builders for the commands only the app can run

    public static func replaceResponse(_ payload: ReplacePayload) throws -> CLIResponse {
        var lines: [String] = []
        if payload.matches == 0 {
            lines.append("No transcript contains '\(payload.find)'. Nothing changed.")
        } else {
            let verb = payload.dryRun ? "would change" : "changed"
            lines.append(
                "\(payload.dryRun ? "Dry run: " : "")\(verb) \(payload.matches) occurrence(s) of "
                    + "'\(payload.find)' to '\(payload.replacement)' "
                    + "across \(payload.segments) segment(s) in \(payload.meetings.count) meeting(s):"
            )
            lines += payload.meetings.map { "  \($0.matches)× in \($0.title) [\($0.id)]" }
            if payload.dryRun {
                lines += ["", "Nothing was written. Run the same command without --dry-run to apply it."]
            } else if payload.summaryInvalidated {
                lines += [
                    "",
                    "The summaries drawn from that text were cleared. Run 'stillnote summarize <id> "
                        + "--allow-remote' to rebuild one.",
                ]
            }
        }
        return CLIResponse(code: .ok, message: lines.joined(separator: "\n"), payload: try CLIJSON(payload))
    }

    public static func meetingResponse(_ message: String, _ meeting: Meeting) throws -> CLIResponse {
        try .success(message, MeetingPayload(meeting, includeSegments: false))
    }

    public static func recordResponse(_ message: String, _ payload: RecordPayload) throws -> CLIResponse {
        try .success(message, payload)
    }

    public static func render(_ payload: RecordPayload) -> String {
        guard let state = payload.state else { return "Nothing is recording." }
        var text = "Recording session \(payload.sessionID ?? "?") is \(state)"
        if let elapsed = payload.elapsed { text += " after \(Formatting.duration(elapsed))" }
        if let error = payload.error { text += "\nError: \(error)" }
        return text + "."
    }

    public static func statusResponse(_ payload: StatusPayload) throws -> CLIResponse {
        var lines: [String] = []
        if payload.running {
            lines.append("Stillnote is running\(payload.ready ? "" : " and still opening its library")." )
        } else {
            lines.append("Stillnote is not running. Reads work; changes and recording need the app open.")
        }
        lines.append("Library: \(payload.dataDirectory)")
        if let meetings = payload.meetings { lines.append("Meetings: \(meetings)") }
        if let ready = payload.speechReady {
            lines.append("Speech model: \(ready ? "ready" : payload.speechDetail ?? "not installed")")
        }
        if let provider = payload.summaryProvider { lines.append("Summary provider: \(provider)") }
        if let recording = payload.recording, recording { lines.append("A recording is in progress.") }
        if let transcribing = payload.transcribing, transcribing { lines.append("A transcription is running.") }
        return CLIResponse(code: .ok, message: lines.joined(separator: "\n"), payload: try CLIJSON(payload))
    }

    /// The status the CLI reports on its own when nothing is listening.
    public static func offlineStatus(paths: Paths, meetings: Int?) throws -> CLIResponse {
        try statusResponse(StatusPayload(
            running: false, ready: false, dataDirectory: paths.dataDirectory.path,
            socket: paths.commandSocketURL.path, meetings: meetings
        ))
    }
}
