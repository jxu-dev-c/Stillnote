import Foundation
import Testing

@testable import StillnoteCore

/// Measures voice recognition against a real library's manual speaker tags. Opt in with
/// STILLNOTE_VOICE_EVAL=1. The library is opened read-only and never written: audio is
/// reached through links in a temporary directory, and voiceprints are cached outside it.
///
/// - STILLNOTE_DATA_DIR / STILLNOTE_MODEL_DIR: the library and a model directory holding
///   `speech/wespeaker-resnet34` (defaults to the standard locations).
/// - STILLNOTE_VOICE_EVAL_CACHE: where voiceprints are cached between runs.
/// - STILLNOTE_TEST_WORKER: the worker to run (defaults to `.build/debug`).
@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["STILLNOTE_VOICE_EVAL"] == "1"),
    .serialized,
    .timeLimit(.minutes(60))
)
struct VoiceRecognitionEvaluationTests {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private var workerURL: URL {
        if let path = environment["STILLNOTE_TEST_WORKER"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/StillnoteSpeechWorker")
    }

    @Test func leaveOneMeetingOutAccuracyOnTheLibrary() async throws {
        let paths = Paths.resolve()
        let store = try Store(paths: paths, readOnly: true)
        let service = VoiceEmbeddingService(modelDirectory: paths.modelDirectory, workerURL: workerURL)
        try #require(service.isAvailable, "Install the speaker model and build the worker first.")
        let cache = URL(fileURLWithPath: environment["STILLNOTE_VOICE_EVAL_CACHE"]
            ?? NSTemporaryDirectory() + "stillnote-voice-eval", isDirectory: true)
        let links = FileManager.default.temporaryDirectory.appendingPathComponent("stillnote-voice-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: links) }

        let profiles = Dictionary(uniqueKeysWithValues: try await store.profiles().map { ($0.id, $0.name) })
        let meetings = try await store.list().filter { !$0.segments.isEmpty && !$0.status.isBusy }
        var prints: [String: MeetingVoiceprints] = [:]
        let started = Date()
        var computed = 0
        for meeting in meetings {
            let fingerprint = VoiceRecognition.fingerprint(of: meeting, modelRevision: service.modelRevision)
            let cached = cache.appendingPathComponent("\(meeting.id).json")
            if let data = try? Data(contentsOf: cached),
               let stored = try? JSONDecoder().decode(MeetingVoiceprints.self, from: data),
               stored.fingerprint == fingerprint {
                prints[meeting.id] = stored
                continue
            }
            let stored = paths.audioURL(meeting.id)
            guard FileManager.default.fileExists(atPath: stored.path) else { continue }
            let suffix = URL(fileURLWithPath: meeting.audioName).pathExtension.lowercased()
            let link = links.appendingPathComponent(meeting.id).appendingPathExtension(suffix.isEmpty ? "wav" : suffix)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: stored)
            let begin = Date()
            do {
                let result = try await service.voiceprints(for: meeting, audioURL: link)
                try JSONEncoder().encode(result).write(to: cached)
                prints[meeting.id] = result
                computed += 1
                print(String(format: "voiceprints %@ %.0fs audio in %.1fs (%d labels)", meeting.id,
                             meeting.duration, Date().timeIntervalSince(begin), result.voiceprints.count))
            } catch {
                print("FAILED \(meeting.id): \(error.localizedDescription)")
            }
        }
        print(String(format: "computed %d meetings in %.0fs", computed, Date().timeIntervalSince(started)))

        var samples: [VoiceSample] = []
        for meeting in meetings {
            guard let stored = prints[meeting.id] else { continue }
            samples += VoiceSample.training(from: meeting, voiceprints: stored)
        }
        let byProfile = Dictionary(grouping: samples, by: \.profileID)
        print("samples \(samples.count) from \(Set(samples.map(\.meetingID)).count) meetings, \(byProfile.count) profiles")

        for scorer in VoiceScorer.allCases {
            let result = VoiceCalibration.calibrate(samples, scorers: [scorer])
            let m = result.metrics
            print(String(format: "%@: threshold %.2f margin %.2f → precision %.3f coverage %.3f (correct %d wrong %d abstained %d; recognizable %d, strangers %d)",
                         scorer.rawValue, result.rule.threshold, result.rule.margin, m.precision, m.coverage,
                         m.correct, m.wrong, m.abstained, m.recognizable, m.strangers))
            let trials = VoiceCalibration.trials(samples, scorer: scorer)
            let rank1 = trials.filter(\.recognizable).filter { $0.candidates.first?.profileID == $0.truth }.count
            print(String(format: "  top-1 identification among recognizable: %.3f", Double(rank1) / Double(max(1, m.recognizable))))
            for threshold in stride(from: 0.3, through: 0.8, by: 0.05) {
                let metrics = VoiceCalibration.evaluate(trials, rule: VoiceRule(scorer: scorer, threshold: threshold, margin: result.rule.margin))
                print(String(format: "  τ=%.2f precision %.3f coverage %.3f wrong %d", threshold, metrics.precision, metrics.coverage, metrics.wrong))
            }
        }

        let chosen = VoiceCalibration.calibrate(samples, scorers: VoiceScorer.allCases)
        print("chosen: \(chosen.rule)")
        let matcher = VoiceMatcher(samples: samples, scorer: chosen.rule.scorer)
        let trials = VoiceCalibration.trials(samples, scorer: chosen.rule.scorer)
        for (trial, sample) in zip(trials, samples) {
            let match = chosen.rule.decide(speaker: sample.speaker, candidates: trial.candidates)
            guard match.decision == .assigned, match.profileID != trial.truth else { continue }
            print(String(format: "  wrong: %@ %@ is %@, matched %@ (%.3f vs %.3f)", sample.meetingID, sample.speaker,
                         profiles[trial.truth] ?? "?", profiles[match.profileID ?? ""] ?? "?",
                         match.score ?? 0, match.runnerUpScore ?? 0))
        }

        print("\nUntagged labels:")
        for meeting in meetings {
            guard let stored = prints[meeting.id] else { continue }
            let matches = chosen.rule.match(stored, meeting: meeting, matcher: matcher)
            guard !matches.isEmpty, meeting.speakerProfiles.isEmpty else { continue }
            print("\(meeting.title) [\(meeting.id)]")
            for match in matches {
                let speech = stored.voiceprints.first { $0.speaker == match.speaker }?.speechSeconds ?? 0
                print(String(format: "  %@ (%.0fs) → %@ %@ %.3f (next %@ %.3f)", match.speaker, speech, match.decision.rawValue,
                             profiles[match.profileID ?? ""] ?? "-", match.score ?? 0,
                             profiles[match.runnerUpID ?? ""] ?? "-", match.runnerUpScore ?? 0))
            }
        }
        #expect(!samples.isEmpty)
    }
}
