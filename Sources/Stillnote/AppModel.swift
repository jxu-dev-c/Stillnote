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
    var settings = AppSettings()
    private(set) var speech = SpeechStatus.current(modelDirectory: URL(fileURLWithPath: "/"))
    private(set) var agents: [AgentAvailability] = AgentRunner.availability()
    private(set) var capabilities = CaptureCapabilities(
        available: false, reason: nil, microphones: [], displays: [], defaultDisplayID: nil
    )
    var startupError: String?
    var alertMessage: String?

    let paths: Paths
    let store: Store
    let recorder: RecordingCoordinator

    private let queue = JobQueue()
    private let installer: ModelInstaller
    private var transcriptions: [String: Task<Void, Never>] = [:]
    private var installTask: Task<Void, Never>?
    private var installProgress = 0.0
    private var installDetail: String?
    private var installError: String?
    private var installing = false

    init() {
        var resolved: Paths
        var openedStore: Store?
        var failure: String?
        do {
            resolved = try Paths.standard()
            openedStore = try Store(paths: resolved)
        } catch {
            // A read-only or missing Application Support directory is unrecoverable;
            // fall back to a temporary location so the window can explain itself.
            failure = error.localizedDescription
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("stillnote-unavailable-\(UUID().uuidString)", isDirectory: true)
            resolved = Paths(
                dataDirectory: fallback.appendingPathComponent("data"),
                modelDirectory: fallback.appendingPathComponent("models")
            )
            openedStore = try? Store(paths: resolved)
        }
        paths = resolved
        store = openedStore!
        startupError = failure
        installer = ModelInstaller(modelDirectory: paths.modelDirectory)
        recorder = RecordingCoordinator(store: store, paths: paths)
    }

    // MARK: - Loading

    func load() async {
        do {
            try await store.markInterruptedJobs()
            meetings = try await store.list()
            settings = try await store.settings()
        } catch {
            startupError = error.localizedDescription
        }
        await recorder.recover()
        refreshEnvironment()
    }

    func refreshEnvironment() {
        speech = SpeechStatus.current(
            modelDirectory: paths.modelDirectory, model: settings.transcription.model,
            installing: installing, progress: installProgress, installDetail: installDetail,
            error: installError
        )
        agents = AgentRunner.availability()
        capabilities = CaptureDeviceCatalog.capabilities()
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
                language: language, speakerCount: count
            )
        }
        transcriptions[id] = task
    }

    private func runTranscription(
        id: String, service: TranscriptionService, audioURL: URL, model: String,
        language: String, speakerCount: Int?
    ) async {
        defer { transcriptions[id] = nil }
        if Task.isCancelled {
            await markTranscriptionStopped(id)
            return
        }
        do {
            let result = try await service.transcribe(
                audioURL: audioURL, model: model, language: language, speakerCount: speakerCount
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
            refreshEnvironment()
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
        refreshEnvironment()
        let model = settings.transcription.model
        let installer = installer
        installTask = await queue.enqueue { [self] in
            do {
                try await installer.install(model: model) { update in
                    Task { @MainActor [self] in
                        self.installProgress = update.fraction * 100
                        self.installDetail = update.detail
                        self.refreshEnvironment()
                    }
                }
                await MainActor.run { [self] in
                    self.installing = false
                    self.installProgress = 100
                    self.installError = nil
                    self.installDetail = nil
                    self.refreshEnvironment()
                }
            } catch {
                await MainActor.run { [self] in
                    self.installing = false
                    self.installError = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    self.installDetail = "Model setup failed. Try again."
                    self.refreshEnvironment()
                }
            }
        }
    }

    func shutdown() async {
        for task in transcriptions.values { task.cancel() }
        await recorder.shutdown()
    }
}
