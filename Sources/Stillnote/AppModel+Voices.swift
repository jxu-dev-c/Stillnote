import Foundation
import StillnoteCore

/// Learn Voices or a library-wide auto-tag, while it runs.
struct VoiceJob: Equatable {
    enum Kind: Equatable { case learning, autoTagging }

    var kind: Kind
    var detail: String
    /// 0–1 when the amount of work is known.
    var fraction: Double?
}

/// Voice recognition: Learn Voices reads a voiceprint for every manually tagged speaker and
/// calibrates how confident a match must be against those tags; Auto-Tag links the speakers
/// of a meeting that match a profile confidently. Every model run goes through `JobQueue` one
/// meeting at a time, so a transcription started meanwhile waits for at most one meeting.
extension AppModel {
    var voiceService: VoiceEmbeddingService { VoiceEmbeddingService(modelDirectory: paths.modelDirectory) }

    /// Labels in a meeting that auto-tagging may still link.
    func untaggedSpeakers(_ meeting: Meeting) -> [String] {
        meeting.orderedSpeakerIDs().filter {
            $0 != VoiceRecognition.unknownSpeaker && meeting.speakerProfiles[$0] == nil
        }
    }

    /// Why a meeting can't be auto-tagged right now, or nil when it can.
    func autoTagBlocker(_ meeting: Meeting) -> String? {
        if voiceModel == nil { return "Learn voices in Settings → Speakers first." }
        if meeting.segments.isEmpty { return "Transcribe this meeting first." }
        if meeting.status.isBusy || splittingMeetings.contains(meeting.id) { return "Wait for this meeting to finish processing." }
        if autoTaggingMeetings.contains(meeting.id) { return "Recognizing speakers…" }
        if untaggedSpeakers(meeting).isEmpty { return "Every speaker already has a profile." }
        return nil
    }

    // MARK: - Learn Voices

    /// Starts learning in the background. Returns false when a voice job is already running.
    @discardableResult
    func learnVoices() -> Bool {
        guard isReady, voiceJob == nil else { return false }
        voiceStatusMessage = nil
        voiceJob = VoiceJob(kind: .learning, detail: "Preparing to learn voices")
        voiceTask = Task { [weak self] in await self?.runLearning() }
        return true
    }

    func cancelVoiceJob() {
        voiceTask?.cancel()
        voiceStep?.cancel()
    }

    func forgetVoices() async {
        cancelVoiceJob()
        await voiceTask?.value
        do {
            try await store.forgetVoices()
            voiceModel = nil
            autoTagResults = [:]
            lastBulkAutoTag = []
            voiceStatusMessage = "Learned voices were removed. Speaker tags are unchanged."
        } catch {
            report(error)
        }
    }

    private func runLearning() async {
        defer {
            voiceJob = nil
            voiceTask = nil
        }
        do {
            try await installVoiceModelIfNeeded()
            let service = voiceService
            // Without the worker every meeting would fail; say why instead of skipping them all.
            guard service.isAvailable else { throw SpeechError.message(SpeechWorkerLocator.repairMessage) }
            voiceJob = VoiceJob(kind: .learning, detail: "Finding tagged meetings")
            var pending: [String] = []
            for item in meetings {
                try Task.checkCancellation()
                guard let meeting = try? await store.get(item.id), hasSettledTranscript(meeting),
                      meeting.speakerProfiles.keys.contains(where: { meeting.autoSpeakerProfiles[$0] == nil })
                else { continue }
                let fingerprint = VoiceRecognition.fingerprint(of: meeting, modelRevision: service.modelRevision)
                if (try? await store.voiceprints(item.id))?.fingerprint != fingerprint { pending.append(item.id) }
            }
            var skipped = 0
            for (index, id) in pending.enumerated() {
                try Task.checkCancellation()
                let total = Double(pending.count)
                voiceJob = VoiceJob(
                    kind: .learning, detail: "Learning voices · \(index + 1) of \(pending.count) meetings",
                    fraction: Double(index) / total
                )
                do {
                    _ = try await readVoices(id, service: service) { [weak self] percent in
                        Task { @MainActor in
                            guard let self, self.voiceJob?.kind == .learning else { return }
                            self.voiceJob?.fraction = (Double(index) + percent / 100) / total
                        }
                    }
                } catch {
                    if Self.isCancellation(error) { throw CancellationError() }
                    skipped += 1
                }
            }
            voiceJob = VoiceJob(kind: .learning, detail: "Checking accuracy against your tags", fraction: 1)
            let (samples, contributing) = try await store.voiceSamples(modelRevision: service.modelRevision)
            guard !samples.isEmpty else {
                voiceStatusMessage = "Link speakers to profiles in a few meetings first. Learn Voices learns from those tags."
                return
            }
            let result = await Task.detached(priority: .userInitiated) { VoiceCalibration.calibrate(samples) }.value
            let model = VoiceModel(
                modelRevision: service.modelRevision, learnedAt: Meeting.now(), rule: result.rule,
                calibrated: result.calibrated, metrics: result.metrics,
                profileCount: Set(samples.map(\.profileID)).count, sampleCount: samples.count,
                meetingCount: contributing, skippedMeetings: skipped
            )
            try await store.saveVoiceModel(model)
            voiceModel = model
            voiceStatusMessage = skipped == 0 ? nil
                : "\(skipped) tagged \(skipped == 1 ? "meeting" : "meetings") couldn't be read and \(skipped == 1 ? "was" : "were") skipped."
        } catch {
            voiceStatusMessage = Self.isCancellation(error)
                ? "Learning stopped. Voices read so far are kept for next time."
                : Self.describe(error)
        }
    }

    private func installVoiceModelIfNeeded() async throws {
        guard !voiceService.isInstalled else { return }
        let megabytes = (try? SpeechCatalog.spec(SpeechCatalog.speakerModel))?.downloadMegabytes ?? 15
        voiceJob = VoiceJob(kind: .learning, detail: "Downloading the voice model (\(megabytes) MB)", fraction: 0)
        let installer = installer
        try await queued {
            try await installer.install(model: SpeechCatalog.speakerModel) { update in
                Task { @MainActor [weak self] in
                    guard let self, self.voiceJob?.kind == .learning else { return }
                    self.voiceJob?.fraction = update.fraction
                }
            }
        }
    }

    /// Whether a meeting has a transcript that nothing is changing. Missing audio is not checked
    /// here: current voiceprints don't need it, and otherwise reading fails with a reason the
    /// caller reports as a skipped meeting.
    private func hasSettledTranscript(_ meeting: Meeting) -> Bool {
        !meeting.segments.isEmpty && !meeting.status.isBusy && !splittingMeetings.contains(meeting.id)
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// The meeting's current voiceprints, computing and saving them on the job queue when they
    /// are missing or stale.
    private func readVoices(
        _ id: String, service: VoiceEmbeddingService,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> (Meeting, MeetingVoiceprints) {
        let store = store, paths = paths
        return try await queued {
            let meeting = try await store.get(id)
            guard !meeting.status.isBusy else { throw ValidationError("Wait for this meeting to finish processing.") }
            guard !meeting.segments.isEmpty else { throw ValidationError("Transcribe this meeting first.") }
            let fingerprint = VoiceRecognition.fingerprint(of: meeting, modelRevision: service.modelRevision)
            if let stored = try await store.voiceprints(id), stored.fingerprint == fingerprint {
                return (meeting, stored)
            }
            guard FileManager.default.fileExists(atPath: paths.audioURL(id).path) else {
                throw ValidationError("This meeting's audio is missing.")
            }
            let prints = try await service.voiceprints(
                for: meeting, audioURL: MediaFile.audioURL(for: meeting, paths: paths)
            ) { percent, _ in progress(percent) }
            try await store.saveVoiceprints(prints)
            return (meeting, prints)
        }
    }

    /// Runs one step on the shared job queue so it never competes with a transcription, and
    /// lets Cancel reach the worker the step started.
    private func queued<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let box = QueuedResult<T>()
        let task = await queue.enqueue {
            do {
                try Task.checkCancellation()
                await box.set(.success(try await operation()))
            } catch {
                await box.set(.failure(error))
            }
        }
        voiceStep = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if voiceStep == task { voiceStep = nil }
        guard let result = await box.result else { throw CancellationError() }
        return try result.get()
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if case SpeechError.cancelled = error { return true }
        return false
    }

    // MARK: - Auto-Tag

    /// Links the confident matches among a meeting's untagged speakers, or with `dryRun`
    /// only reports them.
    @discardableResult
    func autoTag(_ id: String, dryRun: Bool = false) async throws -> AutoTagOutcome {
        guard let model = voiceModel else { throw ValidationError("Learn voices first, in Settings → Speakers.") }
        guard !splittingMeetings.contains(id) else { throw ValidationError("Wait for recording splitting to finish.") }
        guard !autoTaggingMeetings.contains(id) else { throw ValidationError("This meeting is already being auto-tagged.") }
        autoTaggingMeetings.insert(id)
        defer { autoTaggingMeetings.remove(id) }
        let service = voiceService
        try requireCurrentModel(model, service: service)
        let samples = try await store.voiceSamples(modelRevision: service.modelRevision).samples
        let outcome = try await autoTagStep(id, model: model, samples: samples, service: service, dryRun: dryRun)
        if !dryRun { autoTagResults[id] = outcome }
        return outcome
    }

    /// Auto-tags every transcribed meeting that still has untagged speakers, in the background.
    @discardableResult
    func autoTagLibrary() -> Bool {
        guard isReady, voiceJob == nil, voiceModel != nil else { return false }
        voiceStatusMessage = nil
        voiceJob = VoiceJob(kind: .autoTagging, detail: "Finding meetings with untagged speakers")
        voiceTask = Task { [weak self] in await self?.runLibraryAutoTag() }
        return true
    }

    private func runLibraryAutoTag() async {
        defer {
            voiceJob = nil
            voiceTask = nil
        }
        var outcomes: [AutoTagOutcome] = []
        var skipped: [AutoTagSkip] = []
        var clearedSummaries = 0
        do {
            guard let model = voiceModel else { return }
            let service = voiceService
            try requireCurrentModel(model, service: service)
            let pending = try await autoTagCandidates()
            let samples = try await store.voiceSamples(modelRevision: service.modelRevision).samples
            for (index, id) in pending.enumerated() {
                try Task.checkCancellation()
                voiceJob = VoiceJob(
                    kind: .autoTagging, detail: "Auto-tagging · \(index + 1) of \(pending.count) meetings",
                    fraction: Double(index) / Double(pending.count)
                )
                // Already being auto-tagged from its transcript, so not skipped.
                guard !autoTaggingMeetings.contains(id) else { continue }
                autoTaggingMeetings.insert(id)
                defer { autoTaggingMeetings.remove(id) }
                do {
                    guard !splittingMeetings.contains(id) else {
                        throw ValidationError("Wait for recording splitting to finish.")
                    }
                    let hadSummary = (try? await store.get(id))?.summary != nil
                    let outcome = try await autoTagStep(id, model: model, samples: samples, service: service, dryRun: false)
                    if hadSummary, !outcome.applied.isEmpty, (try? await store.get(id))?.summary == nil {
                        clearedSummaries += 1
                    }
                    autoTagResults[id] = outcome
                    outcomes.append(outcome)
                } catch {
                    if Self.isCancellation(error) { throw CancellationError() }
                    // A meeting deleted meanwhile is simply gone; any other failure is reported.
                    if let meeting = try? await store.get(id) {
                        skipped.append(AutoTagSkip(id: id, title: meeting.title, reason: Self.describe(error)))
                    }
                }
            }
            lastBulkAutoTag = outcomes
            voiceStatusMessage = AutoTagOutcome.librarySummary(
                outcomes, skipped: skipped, clearedSummaries: clearedSummaries
            )
        } catch {
            lastBulkAutoTag = outcomes
            voiceStatusMessage = Self.isCancellation(error)
                ? "Auto-tagging stopped. Speakers tagged so far are kept."
                : Self.describe(error)
        }
    }

    /// Transcribed meetings, newest first, that still have untagged speakers.
    func autoTagCandidates() async throws -> [String] {
        var pending: [String] = []
        for item in meetings {
            try Task.checkCancellation()
            guard let meeting = try? await store.get(item.id), hasSettledTranscript(meeting),
                  !untaggedSpeakers(meeting).isEmpty
            else { continue }
            pending.append(item.id)
        }
        return pending
    }

    private func autoTagStep(
        _ id: String, model: VoiceModel, samples: [VoiceSample], service: VoiceEmbeddingService, dryRun: Bool
    ) async throws -> AutoTagOutcome {
        let (meeting, prints) = try await readVoices(id, service: service)
        let matcher = VoiceMatcher(samples: samples, scorer: model.rule.scorer)
        let matches = model.rule.match(prints, meeting: meeting, matcher: matcher)
        guard !dryRun else { return AutoTagOutcome(meetingID: id, matches: matches, applied: [], dryRun: true) }
        let (updated, applied) = try await store.applyVoiceMatches(
            matches, meetingID: id, fingerprint: prints.fingerprint, modelRevision: prints.modelRevision
        )
        if !applied.isEmpty { await apply(updated) }
        return AutoTagOutcome(meetingID: id, matches: matches, applied: applied.map(\.speaker), dryRun: false)
    }

    private func requireCurrentModel(_ model: VoiceModel, service: VoiceEmbeddingService) throws {
        guard model.modelRevision == service.modelRevision else {
            throw ValidationError("The voice model was updated. Learn voices again in Settings → Speakers.")
        }
    }

    /// Opt-in: a fresh transcript's speakers are matched as soon as it is saved. A failure is
    /// silent; the speakers simply stay untagged.
    func autoTagAfterTranscription(_ id: String) {
        guard settings.speakerRecognition.autoTagAfterTranscription, voiceModel != nil else { return }
        Task { [weak self] in _ = try? await self?.autoTag(id) }
    }
}

private actor QueuedResult<T: Sendable> {
    private(set) var result: Result<T, Error>?
    func set(_ result: Result<T, Error>) { self.result = result }
}
