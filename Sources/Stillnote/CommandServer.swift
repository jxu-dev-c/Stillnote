import Foundation
import StillnoteCore

/// Serves `stillnote` commands over a Unix domain socket in the library directory.
///
/// Every change arrives here rather than being written to SQLite by the CLI, for two reasons:
/// `Store.update` is a read-modify-write over a whole meeting document, so a second writer would
/// silently drop the app's concurrent edits; and `AppModel.meetings` is the interface's only
/// source of truth, with no file watcher, so an external write would stay invisible until relaunch.
/// Routing through `AppModel` means a correction made in the terminal appears in the open window.
@MainActor
final class CommandServer {
    private weak var model: AppModel?
    private var listener: CommandListener?
    private var loop: Task<Void, Never>?

    var socketPath: String? { listener?.path }

    /// Called once the app has a store and a recorder; commands that arrive before then are
    /// refused rather than reaching a half-built workspace.
    func start(model: AppModel) {
        guard listener == nil, model.settings.cli.enabled else { return }
        let path = model.paths.commandSocketURL.path
        do {
            let listener = try CommandListener(path: path)
            self.listener = listener
            self.model = model
            loop = Task.detached(priority: .utility) { [weak self] in
                while !Task.isCancelled, let connection = listener.accept() {
                    guard let self else {
                        connection.close()
                        return
                    }
                    await self.serve(connection)
                }
            }
        } catch {
            // A missing command socket must never stop the app from opening. The most likely
            // cause is a second instance, which is already serving this library.
            NSLog("Stillnote: the command interface is unavailable (%@)", error.localizedDescription)
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        listener?.close()
        listener = nil
    }

    /// Reads one request and writes one response. Reads and writes block, so they stay off the
    /// main actor; only `handle` hops onto it.
    private nonisolated func serve(_ connection: CommandConnection) async {
        defer { connection.close() }
        let response: CLIResponse
        do {
            guard let line = try connection.readLine() else { return }
            let request = try JSONDecoder().decode(CLIRequest.self, from: Data(line.utf8))
            response = await handle(request)
        } catch let error as DecodingError {
            _ = error
            response = CLIResponse(code: .usage, message: "That request could not be read.")
        } catch {
            response = CLIResponse.failure(error)
        }
        let encoded = (try? JSONEncoder().encode(response))
            ?? Data(#"{"code":"failed","message":"The reply could not be encoded."}"#.utf8)
        try? connection.write(line: String(decoding: encoded, as: UTF8.self))
    }

    // MARK: - Dispatch

    func handle(_ request: CLIRequest) async -> CLIResponse {
        guard let model else { return CLIResponse(code: .unavailable, message: "Stillnote is shutting down.") }
        guard model.settings.cli.enabled else {
            return CLIResponse(
                code: .unavailable,
                message: "Stillnote's command interface is switched off in Settings → Advanced."
            )
        }
        guard model.isReady else {
            return CLIResponse(
                code: .notReady,
                message: "Stillnote is still opening its library. Try again in a moment."
            )
        }
        do {
            if let response = try await CommandRunner.read(request, store: model.store) { return response }
            return try await run(request, model: model)
        } catch {
            return CLIResponse.failure(error)
        }
    }

    private func run(_ request: CLIRequest, model: AppModel) async throws -> CLIResponse {
        switch request.command {
        case ["status"]:
            return try CommandRunner.statusResponse(StatusPayload(
                running: true, ready: model.isReady,
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                dataDirectory: model.paths.dataDirectory.path,
                socket: socketPath ?? model.paths.commandSocketURL.path,
                meetings: model.meetings.count, speechReady: model.speech.ready,
                speechDetail: model.speech.detail, recording: model.recorder.session?.status.isActive ?? false,
                transcribing: model.isTranscribing, summaryProvider: model.settings.summary.provider.rawValue,
                captureAvailable: model.capabilities.available
            ))
        case ["devices"]:
            return try .success(render(model.capabilities), DevicesPayload(model.capabilities))
        case ["transcript", "replace"]:
            return try await replace(request, model: model)
        case ["transcript", "set"]:
            return try await setSegment(request, model: model)
        case ["speaker", "rename"]:
            return try await renameSpeaker(request, model: model)
        case ["summary", "set"]:
            return try await setSummary(request, model: model)
        case ["notes", "set"]:
            return try await setNotes(request, model: model)
        case ["transcribe"]:
            return try await transcribe(request, model: model)
        case ["summarize"]:
            return try await summarize(request, model: model)
        case ["record", "status"]:
            let payload = RecordPayload(session: model.recorder.session)
            return try CommandRunner.recordResponse(CommandRunner.render(payload), payload)
        case ["record", "start"]:
            return try await recordStart(request, model: model)
        case ["record", "stop"]:
            return try await recordStop(request, model: model)
        case ["record", "pause"], ["record", "resume"], ["record", "discard"]:
            return try await recordTransition(request, model: model)
        default:
            throw CLIError.usage("'\(request.command.joined(separator: " "))' is not a command this app serves.")
        }
    }

    // MARK: - Helpers

    private func resolve(_ request: CLIRequest, model: AppModel) throws -> Meeting {
        guard let reference = request.positionals.first else {
            throw CLIError.usage("Name a meeting, or use 'latest'.")
        }
        return try MeetingQuery.resolve(reference, in: model.meetings)
    }

    private func requireIdle(_ meeting: Meeting) throws {
        guard !meeting.status.isBusy else {
            throw CLIError.busy("'\(meeting.title)' is \(meeting.status.rawValue). Wait for it to finish.")
        }
    }

    /// `AppModel.edit` reports failures through the interface's alert rather than throwing, so a
    /// nil result here means the store rejected the change.
    private func edited(_ meeting: Meeting?, _ what: String) throws -> Meeting {
        guard let meeting else { throw CLIError.failed("\(what) could not be saved.") }
        return meeting
    }

    private func render(_ capabilities: CaptureCapabilities) -> String {
        var lines: [String] = []
        if !capabilities.available {
            lines.append(capabilities.reason ?? "Recording is unavailable on this Mac.")
        }
        lines.append("Microphones:")
        lines += capabilities.microphones.isEmpty
            ? ["  (none found)"]
            : capabilities.microphones.map { "  \($0.id)  \($0.name)" }
        lines.append("Displays:")
        lines += capabilities.displays.isEmpty
            ? ["  (none found)"]
            : capabilities.displays.map { "  \($0.id)  \($0.name)" }
        return lines.joined(separator: "\n")
    }

    // MARK: - Transcript

    private func replace(_ request: CLIRequest, model: AppModel) async throws -> CLIResponse {
        guard request.positionals.count == 2 else {
            throw CLIError.usage("Give the text to find and the text to put in its place.")
        }
        let scoped = request.value("meeting")
        guard scoped != nil || request.has("all") else {
            throw CLIError.usage(
                "Choose a scope: --meeting <id> for one meeting, or --all for every transcript."
            )
        }
        guard !(scoped != nil && request.has("all")) else {
            throw CLIError.usage("Use either --meeting or --all, not both.")
        }
        let options = ReplaceOptions(
            find: request.positionals[0], replacement: request.positionals[1],
            regex: request.has("regex"), ignoreCase: request.has("ignore-case"),
            wholeWord: request.has("whole-word")
        )
        let targets: [Meeting]
        if let scoped {
            let meeting = try MeetingQuery.resolve(scoped, in: model.meetings)
            try requireIdle(meeting)
            targets = [meeting]
        } else {
            // A busy meeting is skipped rather than failing the whole sweep: its transcript is
            // about to be rewritten by the job that owns it.
            targets = model.meetings.filter { !$0.status.isBusy }
        }
        let dryRun = request.has("dry-run")
        var changes: [ReplaceChange] = []
        var invalidated = false
        for meeting in targets {
            let outcome = try TranscriptEdit.preview(meeting, options: options)
            guard !outcome.isEmpty else { continue }
            guard !dryRun else {
                if meeting.summary != nil { invalidated = true }
                changes.append(ReplaceChange(id: meeting.id, title: meeting.title, outcome: outcome))
                continue
            }
            // The store's mutation closure cannot throw, so carry the result out rather than
            // discarding an error the preview did not already catch.
            var applied: Result<ReplaceOutcome, Error>?
            let saved = await model.edit(meeting.id) { meeting in
                applied = Result { try TranscriptEdit.replace(in: &meeting, options: options) }
            }
            _ = try edited(saved, "The transcript correction")
            guard let applied = try applied?.get(), !applied.isEmpty else { continue }
            if meeting.summary != nil { invalidated = true }
            changes.append(ReplaceChange(id: meeting.id, title: meeting.title, outcome: applied))
        }
        return try CommandRunner.replaceResponse(ReplacePayload(
            find: options.find, replacement: options.replacement, dryRun: dryRun, changes: changes,
            summaryInvalidated: invalidated
        ))
    }

    private func setSegment(_ request: CLIRequest, model: AppModel) async throws -> CLIResponse {
        let meeting = try resolve(request, model: model)
        try requireIdle(meeting)
        guard let segmentID = request.value("segment") else {
            throw CLIError.usage("Name the segment with --segment. 'stillnote show <id> --segments' lists them.")
        }
        guard let index = meeting.segments.firstIndex(where: { $0.id == segmentID }) else {
            throw CLIError.notFound("'\(meeting.title)' has no segment '\(segmentID)'.")
        }
        let text = request.value("text")
        let speaker = request.value("speaker")
        guard text != nil || speaker != nil else {
            throw CLIError.usage("Give --text, --speaker, or both.")
        }
        if let speaker, meeting.speakers[speaker] == nil {
            let known = meeting.orderedSpeakerIDs().joined(separator: ", ")
            throw CLIError.usage("'\(speaker)' is not a speaker in this meeting. Known speakers: \(known).")
        }
        if let text, text.count > Validation.maxSegmentTextLength {
            throw CLIError.usage("That segment text is too long to save.")
        }
        let saved = try edited(
            await model.editTranscriptReturning(meeting.id) { meeting in
                if let text { meeting.segments[index].text = text }
                if let speaker { meeting.segments[index].speaker = speaker }
            },
            "The segment"
        )
        return try CommandRunner.meetingResponse(
            "Updated segment \(segmentID) in '\(saved.title)'."
                + (saved.summary == nil && meeting.summary != nil
                    ? " Its summary was cleared; run 'stillnote summarize \(saved.id) --allow-remote' to rebuild one."
                    : ""),
            saved
        )
    }

    private func renameSpeaker(_ request: CLIRequest, model: AppModel) async throws -> CLIResponse {
        let meeting = try resolve(request, model: model)
        try requireIdle(meeting)
        guard let speakerID = request.value("speaker"), let name = request.value("name") else {
            throw CLIError.usage("Give --speaker <id> and --name <name>. 'stillnote show <id>' lists speakers.")
        }
        guard meeting.speakers[speakerID] != nil else {
            let known = meeting.orderedSpeakerIDs().joined(separator: ", ")
            throw CLIError.notFound("'\(speakerID)' is not a speaker in this meeting. Known speakers: \(known).")
        }
        // Reuses the store's own rename path, which validates the name and clears a summary that
        // quoted the old one in exactly the way the interface does.
        try await model.assignSpeakerProfile(
            nil, meetingID: meeting.id, speakerID: speakerID, localName: name
        )
        guard let saved = model.meeting(meeting.id) else {
            throw CLIError.failed("The speaker rename could not be read back.")
        }
        return try CommandRunner.meetingResponse(
            "Renamed \(speakerID) to '\(saved.speakerName(speakerID))' in '\(saved.title)'.", saved
        )
    }

    // MARK: - Summary and notes

    private func setSummary(_ request: CLIRequest, model: AppModel) async throws -> CLIResponse {
        let meeting = try resolve(request, model: model)
        try requireIdle(meeting)
        if request.has("json-stdin") {
            guard let body = request.standardInput, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw CLIError.usage("--json-stdin expects a summary document on stdin.") }
            let replacement: MeetingSummary
            do {
                replacement = try JSONDecoder().decode(MeetingSummary.self, from: Data(body.utf8))
            } catch {
                throw CLIError.usage(
                    "That is not a summary document. It needs overview, key_points, decisions, "
                        + "action_items, provider, model, and generated_at."
                )
            }
            let saved = try edited(
                await model.edit(meeting.id) { $0.summary = replacement; $0.status = .complete },
                "The summary"
            )
            return try CommandRunner.meetingResponse("Replaced the summary of '\(saved.title)'.", saved)
        }
        guard let overview = request.value("overview") else {
            throw CLIError.usage("Give --overview <text>, or --json-stdin with a full summary document.")
        }
        guard var summary = meeting.summary else {
            throw CLIError.usage(
                "'\(meeting.title)' has no summary to edit. Use --json-stdin to write a whole one, or "
                    + "'stillnote summarize \(meeting.id) --allow-remote' to generate it."
            )
        }
        summary.overview = overview
        let saved = try edited(await model.edit(meeting.id) { $0.summary = summary }, "The summary")
        return try CommandRunner.meetingResponse("Updated the overview of '\(saved.title)'.", saved)
    }

    private func setNotes(_ request: CLIRequest, model: AppModel) async throws -> CLIResponse {
        let meeting = try resolve(request, model: model)
        let text: String
        if request.has("stdin") {
            guard let body = request.standardInput else { throw CLIError.usage("--stdin expects notes on stdin.") }
            text = body
        } else if let value = request.value("text") {
            text = value
        } else {
            throw CLIError.usage("Give --text <notes>, or --stdin to read them from a pipe.")
        }
        guard text.count <= Validation.maxNotesLength else {
            throw CLIError.usage("Notes must be at most \(Validation.maxNotesLength) characters.")
        }
        let saved = try edited(await model.edit(meeting.id) { $0.notes = text }, "The notes")
        // The window keeps an unsaved draft in UserDefaults; leaving it would let a stale draft
        // overwrite this on the next autosave.
        model.discardNotesDraft(saved.id)
        return try .success(
            text.isEmpty ? "Cleared the notes on '\(saved.title)'." : "Saved notes on '\(saved.title)'.",
            TextPayload(id: saved.id, text: text)
        )
    }

    // MARK: - Jobs

    private func transcribe(_ request: CLIRequest, model: AppModel) async throws -> CLIResponse {
        let meeting = try resolve(request, model: model)
        try requireIdle(meeting)
        guard model.speech.ready else { throw CLIError.failed(model.speech.detail) }
        let language = try request.value("language").map { try Validation.language($0) }
        // Int?? distinguishes "leave the meeting's own setting alone" (outer nil) from "set it",
        // including setting it back to automatic. Spell that out rather than leaning on inference.
        let speakers = try Validation.speakerCount(try request.integer("speakers"))
        let speakerOverride: Int?? = request.value("speakers") == nil ? nil : .some(speakers)
        await model.transcribe(meeting.id, language: language, speakerCount: speakerOverride)
        guard let queued = model.meeting(meeting.id), queued.status == .transcribing else {
            throw CLIError.failed(model.alertMessage ?? "Transcription could not be queued.")
        }
        return try CommandRunner.meetingResponse(
            "Queued local transcription for '\(queued.title)'. Check 'stillnote show \(queued.id)' for progress.",
            queued
        )
    }

    private func summarize(_ request: CLIRequest, model: AppModel) async throws -> CLIResponse {
        let meeting = try resolve(request, model: model)
        try requireIdle(meeting)
        guard meeting.segments.isEmpty == false else {
            throw CLIError.usage("Transcribe '\(meeting.title)' before summarizing it.")
        }
        // The app asks for consent per request before any transcript text reaches an agent. The
        // flag is the CLI's equivalent, so a summary is never sent out on a caller's behalf.
        guard request.has("allow-remote") else {
            throw CLIError.usage(
                "Summarizing sends this transcript to the configured agent CLI "
                    + "(\(model.settings.summary.provider.rawValue)). Pass --allow-remote to consent."
            )
        }
        await model.summarize(meeting.id, allowRemote: true)
        guard let queued = model.meeting(meeting.id), queued.status == .summarizing else {
            throw CLIError.failed(model.alertMessage ?? "The summary could not be queued.")
        }
        return try CommandRunner.meetingResponse(
            "Queued a summary for '\(queued.title)' via \(model.settings.summary.provider.rawValue). "
                + "Check 'stillnote summary show \(queued.id)' shortly.",
            queued
        )
    }

    // MARK: - Recording

    private func recordStart(_ request: CLIRequest, model: AppModel) async throws -> CLIResponse {
        guard model.recorder.session == nil else {
            throw CLIError.busy(
                "A recording is already open. Save it with 'stillnote record stop' or drop it with "
                    + "'stillnote record discard'."
            )
        }
        let title = try Validation.title(request.value("title") ?? defaultRecordingTitle())
        var options = CaptureOptions(title: String(title.prefix(Validation.maxRecordingTitleLength)))
        options.language = try Validation.language(request.value("language") ?? model.settings.transcription.language)
        options.speakerCount = try Validation.speakerCount(
            try request.integer("speakers") ?? model.settings.transcription.speakerCount
        )
        options.systemAudio = !request.has("no-system-audio")
        options.screenVideo = request.has("screen-video")
        if let mic = request.value("mic") {
            guard let device = matchDevice(mic, in: model.capabilities.microphones) else {
                throw CLIError.notFound(
                    "No microphone matches '\(mic)'. Run 'stillnote devices' to list them."
                )
            }
            options.microphoneID = device.id
        }
        if let screen = request.value("screen") {
            guard let display = model.capabilities.displays.first(where: {
                String($0.id) == screen || $0.name.lowercased().contains(screen.lowercased())
            }) else {
                throw CLIError.notFound("No display matches '\(screen)'. Run 'stillnote devices' to list them.")
            }
            options.displayID = display.id
        }
        do {
            try await model.recorder.start(options: options)
        } catch {
            throw CLIError.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        let payload = RecordPayload(session: model.recorder.session)
        return try CommandRunner.recordResponse(
            "Recording '\(options.title)'. Stop it with 'stillnote record stop'.", payload
        )
    }

    private func recordStop(_ request: CLIRequest, model: AppModel) async throws -> CLIResponse {
        guard model.recorder.session != nil else { throw CLIError.notFound("Nothing is recording.") }
        guard let meeting = await model.finishRecording() else {
            throw CLIError.failed(model.alertMessage ?? "The recording could not be saved.")
        }
        var transcribing = false
        if !request.has("no-transcribe"), model.speech.ready {
            await model.transcribe(meeting.id)
            transcribing = model.meeting(meeting.id)?.status == .transcribing
        }
        var message = "Saved '\(meeting.title)' as \(meeting.id) (\(Formatting.duration(meeting.duration)))."
        if transcribing {
            message += " Transcription is queued."
        } else if !request.has("no-transcribe") {
            message += " Transcription was skipped: \(model.speech.detail)"
        }
        let payload = RecordPayload(session: nil, meetingID: meeting.id, transcribing: transcribing)
        return try CommandRunner.recordResponse(message, payload)
    }

    private func recordTransition(_ request: CLIRequest, model: AppModel) async throws -> CLIResponse {
        guard let session = model.recorder.session else { throw CLIError.notFound("Nothing is recording.") }
        let action = request.command[1]
        switch action {
        case "pause":
            guard session.status == .recording else {
                throw CLIError.usage("This recording is \(session.status.rawValue), not recording.")
            }
            model.recorder.pause()
        case "resume":
            guard session.status == .paused else {
                throw CLIError.usage("This recording is \(session.status.rawValue), not paused.")
            }
            model.recorder.resume()
        default:
            await model.recorder.discard()
            return try CommandRunner.recordResponse(
                "Discarded the recording. Its audio was deleted.", RecordPayload(session: nil)
            )
        }
        let payload = RecordPayload(session: model.recorder.session)
        return try CommandRunner.recordResponse(CommandRunner.render(payload), payload)
    }

    private func matchDevice(_ reference: String, in devices: [CaptureDevice]) -> CaptureDevice? {
        devices.first { $0.id == reference }
            ?? devices.first { $0.name.lowercased().contains(reference.lowercased()) }
    }

    private func defaultRecordingTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Recording \(formatter.string(from: Date()))"
    }
}
