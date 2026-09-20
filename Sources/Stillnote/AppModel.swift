import Foundation
import Observation
import StillnoteCore

/// The app's single source of truth. Background jobs write through the store actor and
/// hand back the updated meeting, so a job's progress can never overwrite an edit the
/// user made while it was running.
@MainActor
@Observable
final class AppModel {
    private(set) var meetings: [Meeting] = []
    private(set) var speakerProfiles: [SpeakerProfile] = []
    var settingsTab = "transcription"
    var requestedSpeakerProfileID: String?
    var settings = AppSettings()
    private(set) var speech = SpeechStatus.unknown
    private(set) var agents: [AgentAvailability] = []
    private(set) var capabilities = CaptureCapabilities(
        available: false, reason: nil, microphones: [], displays: [], defaultDisplayID: nil
    )
    private(set) var startupStage = "Preparing your library…"
    private(set) var isReady = false
    private var isLoading = false
    var startupError: String?
    var alertMessage: String?

    /// Everything that needs the filesystem. It is built in `load()`, never in `init`:
    /// resolving paths can touch a folder macOS guards, and the permission prompt for
    /// that cannot appear until the app has a window. Probing during launch deadlocks.
    private var workspace: Workspace?

    var paths: Paths { workspace!.paths }
    var store: Store { workspace!.store }
    var recorder: RecordingCoordinator { workspace!.recorder }

    private let queue = JobQueue()
    private var transcriptions: [String: Task<Void, Never>] = [:]
    private var installTask: Task<Void, Never>?
    private var installProgress = 0.0
    private var installDetail: String?
    private var installError: String?
    private var installing = false

    private struct Workspace {
        let paths: Paths
        let store: Store
        let installer: ModelInstaller
        let recorder: RecordingCoordinator
    }

    init() {}

    // MARK: - Loading

    func load() async {
        // Every window shares this model. Never rerun recovery over active jobs.
        guard !isLoading, !isReady else { return }
        isLoading = true
        startupError = nil
        defer { isLoading = false }
        do {
            if workspace == nil {
                startupStage = "Preparing your library folders…"
                let paths = try await Task.detached { try Paths.standard() }.value
                startupStage = "Opening the meeting database…"
                // Actor initializers run synchronously on their caller. SQLite can
                // wait for a lock, so constructing Store must also leave the UI thread.
                let store = try await Task.detached { try Store(paths: paths) }.value
                workspace = Workspace(
                    paths: paths,
                    store: store,
                    installer: ModelInstaller(modelDirectory: paths.modelDirectory),
                    recorder: RecordingCoordinator(store: store, paths: paths)
                )
            }
            startupStage = "Loading meetings and settings…"
            try await store.markInterruptedJobs()
            try await store.migrateNamedSpeakers()
            meetings = try await store.list()
            settings = try await store.settings()
            speakerProfiles = try await store.profiles()
            startupStage = "Recovering interrupted recordings…"
            await recorder.recover()
            isReady = true
        } catch {
            startupError = error.localizedDescription
            return
        }
        await refreshEnvironment()
    }

    /// Probes the model, MOSS runtime, agent CLIs, and capture devices off the main
    /// actor. Each of those touches the filesystem, and a folder macOS guards can hold
    /// that read until the user answers a prompt — which must never freeze the window.
    func refreshEnvironment() async {
        guard isReady else { return }
        let modelDirectory = paths.modelDirectory
        let model = settings.transcription.model
        let summarySettings = settings.summary
        let state = (installing, installProgress, installDetail, installError)
        let probe = await Task.detached(priority: .userInitiated) {
            (
                SpeechStatus.current(
                    modelDirectory: modelDirectory, model: model, installing: state.0,
                    progress: state.1, installDetail: state.2, error: state.3
                ),
                AgentRunner.availability(settings: summarySettings),
                CaptureDeviceCatalog.capabilities()
            )
        }.value
        speech = probe.0
        agents = probe.1
        capabilities = probe.2
    }

    func meeting(_ id: String) -> Meeting? { meetings.first { $0.id == id } }

    private func apply(_ meeting: Meeting) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.append(meeting)
        }
        meetings.sort { $0.createdAt > $1.createdAt }
    }

    private func report(_ error: Error) {
        alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func deleteSpeakerProfile(_ id: String) async throws {
        let changed = try await store.deleteProfile(id)
        changed.forEach { apply($0) }
        speakerProfiles.removeAll { $0.id == id }
    }

    func saveSpeakerProfile(_ profile: SpeakerProfile) async throws {
        let saved = try await store.saveProfile(profile)
        rememberProfile(saved)
    }

    private func rememberProfile(_ profile: SpeakerProfile) {
        speakerProfiles.removeAll { $0.id == profile.id }
        speakerProfiles.append(profile)
        speakerProfiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func createSpeakerProfile(_ profile: SpeakerProfile, meetingID: String, speakerID: String) async throws {
        let validated = try profile.validated()
        apply(try await store.createProfile(validated, meetingID: meetingID, speakerID: speakerID))
        rememberProfile(validated)
    }

    func assignSpeakerProfile(_ profileID: String?, meetingID: String, speakerID: String,
                              localName: String? = nil) async throws {
        apply(try await store.assignProfile(profileID, meetingID: meetingID,
                                            speakerID: speakerID, localName: localName))
    }

    // MARK: - Meeting edits

    @discardableResult
    func edit(_ id: String, _ mutate: @escaping (inout Meeting) -> Void) async -> Meeting? {
        do {
            let updated = try await store.update(id, mutate)
            apply(updated)
            return updated
        } catch {
            report(error)
            return nil
        }
    }

    /// Transcript and speaker corrections invalidate the summary they were drawn from.
    func editTranscript(_ id: String, _ mutate: @escaping (inout Meeting) -> Void) async {
        await edit(id) { meeting in
            mutate(&meeting)
            for segment in meeting.segments where meeting.speakers[segment.speaker] == nil {
                meeting.speakers[segment.speaker] = segment.speaker
            }
            let hasTranscript = !meeting.segments.isEmpty
            meeting.summary = nil
            meeting.status = hasTranscript ? .transcribed : .ready
            meeting.error = nil
            meeting.progress = hasTranscript ? 100 : 0
            meeting.stage = hasTranscript ? "Transcript ready" : "Ready to transcribe"
        }
    }

    func delete(_ id: String) async {
        guard let meeting = meeting(id), !meeting.status.isBusy else {
            alertMessage = "This meeting is processing. Wait for it to finish."
            return
        }
        MediaFile.forget(id, paths: paths)
        try? FileManager.default.removeItem(at: paths.audioURL(id))
        try? FileManager.default.removeItem(at: paths.videoURL(id))
        do {
            try await store.delete(id)
            meetings.removeAll { $0.id == id }
            UserDefaults.standard.removeObject(forKey: "stillnote:notes:\(id)")
        } catch {
            report(error)
        }
    }

    // MARK: - Import

    func importRecording(from url: URL, title: String, language: String, speakerCount: Int?) async -> Meeting? {
        do {
            let title = try Validation.title(title)
            let language = try Validation.language(language)
            let speakerCount = try Validation.speakerCount(speakerCount)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            guard size > 0 else { throw ValidationError("The audio file is empty.") }
            guard size <= Validation.maxAudioBytes else {
                throw ValidationError("Audio files must be smaller than 2 GB.")
            }
            let duration = try await AudioDecoder.probeDuration(url)
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let destination = paths.audioURL(id)
            try FileManager.default.copyItem(at: url, to: destination)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: destination.path
            )
            let meeting = Meeting(
                id: id, title: title, audioName: String(url.lastPathComponent.prefix(240)),
                language: language, speakerCount: speakerCount, duration: duration
            )
            _ = try await store.insert(meeting)
            apply(meeting)
            return meeting
        } catch {
            report(error)
            return nil
        }
    }

    func finishRecording() async -> Meeting? {
        do {
            let meeting = try await recorder.finish()
            apply(meeting)
            return meeting
        } catch {
            report(error)
            return nil
        }
    }

    // MARK: - Transcription

    var isTranscribing: Bool { !transcriptions.isEmpty }

    func transcribe(_ id: String, language: String? = nil, speakerCount: Int?? = nil) async {
        guard let meeting = meeting(id) else { return }
        guard !meeting.status.isBusy else {
            alertMessage = "This meeting is processing. Wait for it to finish."
            return
        }
        guard !installing else {
            alertMessage = "Wait for model setup to finish."
            return
        }
        guard speech.ready else {
            alertMessage = speech.detail
            return
        }
        let language = language ?? (meeting.language.isEmpty ? settings.transcription.language : meeting.language)
        let count = speakerCount ?? meeting.speakerCount
        let hotWords = settings.transcription.hotWords
        guard let queued = await edit(id, { meeting in
            meeting.status = .transcribing
            meeting.progress = 0
            meeting.stage = "Queued for local transcription"
            meeting.error = nil
            meeting.speakerCount = count
        }) else { return }
        _ = queued

        let service = TranscriptionService(modelDirectory: paths.modelDirectory)
        let audioURL = MediaFile.audioURL(for: meeting, paths: paths)
        let model = settings.transcription.model
        let task = await queue.enqueue { [weak self] in
            await self?.runTranscription(
                id: id, service: service, audioURL: audioURL, model: model,
                language: language, speakerCount: count, hotWords: hotWords
            )
        }
        transcriptions[id] = task
    }

    private func runTranscription(
        id: String, service: TranscriptionService, audioURL: URL, model: String,
        language: String, speakerCount: Int?, hotWords: [String]
    ) async {
        defer { transcriptions[id] = nil }
        if Task.isCancelled {
            await markTranscriptionStopped(id)
            return
        }
        do {
            let result = try await service.transcribe(
                audioURL: audioURL, model: model, language: language, speakerCount: speakerCount, hotWords: hotWords
            ) { [weak self] progress, stage in
                Task { @MainActor in
                    guard let self, self.transcriptions[id] != nil else { return }
                    await self.edit(id) {
                        $0.progress = max(0, min(100, progress))
                        $0.stage = stage
                    }
                }
            }
            if Task.isCancelled {
                await markTranscriptionStopped(id)
                return
            }
            if result.segments.isEmpty {
                await edit(id) {
                    $0.duration = result.duration
                    $0.language = result.language
                    $0.status = .error
                    $0.progress = 100
                    $0.stage = "No speech detected"
                    $0.error = "No speech was detected. Your audio is saved. Check the microphone, "
                        + "language, or try a clearer recording."
                }
                return
            }
            await edit(id) {
                $0.duration = result.duration
                $0.language = result.language
                $0.speakerProfiles = [:]
                $0.speakers = result.speakers
                $0.segments = result.segments
                $0.status = .transcribed
                $0.progress = 100
                $0.stage = "Transcript ready"
                $0.summary = nil
                $0.error = nil
            }
        } catch is CancellationError {
            await markTranscriptionStopped(id)
        } catch SpeechError.cancelled {
            await markTranscriptionStopped(id)
        } catch {
            if Task.isCancelled {
                await markTranscriptionStopped(id)
                return
            }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await edit(id) {
                $0.status = .error
                $0.stage = "Transcription failed"
                $0.error = String(message.prefix(1000))
            }
        }
    }

    /// Stopping preserves the recording, notes, previous transcript, and summary.
    private func markTranscriptionStopped(_ id: String) async {
        await edit(id) { meeting in
            meeting.status = meeting.summary != nil
                ? .complete : (meeting.segments.isEmpty ? .ready : .transcribed)
            meeting.stage = "Transcription stopped"
            meeting.progress = 0
            meeting.error = nil
        }
    }

    func cancelTranscription(_ id: String) async {
        guard let task = transcriptions[id] else { return }
        await edit(id) { $0.stage = "Stopping transcription…" }
        task.cancel()
    }

    // MARK: - Summary

    func summarize(_ id: String, allowRemote: Bool) async {
        guard let meeting = meeting(id) else { return }
        guard !meeting.status.isBusy else {
            alertMessage = "This meeting is processing. Wait for it to finish."
            return
        }
        guard !meeting.segments.isEmpty else {
            alertMessage = "Create a transcript before generating a summary."
            return
        }
        var videoPath: URL?
        if meeting.summaryIncludeVideoPath {
            let candidate = paths.videoURL(id)
            guard meeting.hasVideo, FileManager.default.fileExists(atPath: candidate.path) else {
                alertMessage = "The screen video is missing. Turn off Send video path to AI and retry."
                return
            }
            videoPath = candidate
        }
        await edit(id) {
            $0.status = .summarizing
            $0.progress = 0
            $0.stage = "Queued for summary"
            $0.error = nil
        }
        let settings = settings.summary
        let snapshot = meeting
        let resolvedVideoPath = videoPath
        await queue.enqueue { [weak self] in
            await self?.runSummary(
                id: id, meeting: snapshot, settings: settings, allowRemote: allowRemote,
                videoPath: resolvedVideoPath
            )
        }
    }

    private func runSummary(
        id: String, meeting: Meeting, settings: SummarySettings, allowRemote: Bool, videoPath: URL?
    ) async {
        await edit(id) {
            $0.progress = 30
            $0.stage = "Preparing summary"
        }
        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                try Summarizer.summarize(
                    meeting: meeting, settings: settings, allowRemote: allowRemote, videoPath: videoPath
                )
            }.value
            await edit(id) {
                $0.summary = summary
                $0.status = .complete
                $0.progress = 100
                $0.stage = "Summary ready"
                $0.error = nil
            }
        } catch {
            let message = (error as? SummaryError)?.message
                ?? "Summary failed. Check the provider configuration and try again."
            await edit(id) {
                $0.status = .error
                $0.stage = "Summary failed"
                $0.error = String(message.prefix(1000))
            }
        }
    }

    // MARK: - Settings and models

    func saveSettings(_ updated: AppSettings) async {
        do {
            settings = try await store.saveSettings(updated)
            await refreshEnvironment()
        } catch {
            report(error)
        }
    }

    func installModel() async {
        guard !installing, !meetings.contains(where: { $0.status.isBusy }) else {
            alertMessage = "Wait for current processing to finish before installing models."
            return
        }
        installing = true
        installProgress = 0
        installError = nil
        installDetail = "Preparing local model download"
        await refreshEnvironment()
        let model = settings.transcription.model
        let installer = workspace!.installer
        installTask = await queue.enqueue { [self] in
            do {
                try await installer.install(model: model) { update in
                    Task { @MainActor [self] in
                        self.installProgress = update.fraction * 100
                        self.installDetail = update.detail
                        self.speech.progress = self.installProgress
                        self.speech.detail = update.detail
                    }
                }
                await MainActor.run { [self] in
                    self.installing = false
                    self.installProgress = 100
                    self.installError = nil
                    self.installDetail = nil
                    Task { await self.refreshEnvironment() }
                }
            } catch {
                await MainActor.run { [self] in
                    self.installing = false
                    self.installError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    self.installDetail = "Model setup failed. Try again."
                    Task { await self.refreshEnvironment() }
                }
            }
        }
    }

    func shutdown() async {
        for task in transcriptions.values { task.cancel() }
        await workspace?.recorder.shutdown()
    }
}
