import Foundation
import Testing

@testable import StillnoteCore

private func segment(_ speaker: String, _ start: Double, _ end: Double) -> Segment {
    Segment(id: "segment_\(Int(start * 10))", start: start, end: end, speaker: speaker, text: "words")
}

/// A unit vector along `axis`, nudged toward `blend` so samples of one speaker differ.
private func voice(_ axis: Int, blend: Int? = nil, amount: Float = 0) -> [Float] {
    var vector = [Float](repeating: 0, count: VoiceRecognition.dimension)
    vector[axis] = 1
    if let blend { vector[blend] = amount }
    return VoiceMath.normalized(vector)!
}

struct VoiceWindowPlannerTests {
    @Test func removesOverlapTrimsEdgesAndDropsShortSpans() {
        let plan = VoiceWindowPlanner.plan(segments: [
            segment("speaker_1", 0, 6),
            segment("speaker_2", 5, 9),
            segment("speaker_1", 9, 9.5),
        ], duration: 60)
        let first = plan.windows.filter { $0.speaker == "speaker_1" }
        // 0–5 after removing speaker_2's overlap, trimmed to 0.1–4.9; the 0.5 s span
        // becomes 0.3 s once trimmed and is dropped.
        #expect(first.count == 1)
        #expect(abs(first[0].speechSeconds - 4.8) < 1e-9)
        #expect(abs(plan.speechSeconds["speaker_1"]! - 4.8) < 1e-9)
        // speaker_2 keeps 6–9 trimmed to 6.1–8.9: 2.8 s, under the three-second minimum.
        #expect(plan.tooShort == ["speaker_2"])
        #expect(!plan.windows.contains { $0.speaker == "speaker_2" })
    }

    @Test func skipsTheUnknownLabelButStillRemovesItsOverlap() {
        let plan = VoiceWindowPlanner.plan(segments: [
            segment("speaker_unknown", 0, 30),
            segment("speaker_1", 20, 40),
        ], duration: 60)
        #expect(!plan.windows.contains { $0.speaker == VoiceRecognition.unknownSpeaker })
        #expect(plan.speechSeconds[VoiceRecognition.unknownSpeaker] == nil)
        #expect(plan.windows.allSatisfy { $0.start >= 30 })
    }

    @Test func packsTenSecondWindowsAndKeepsThemInsideTheRecording() {
        let plan = VoiceWindowPlanner.plan(segments: [segment("speaker_1", 0, 25)], duration: 25)
        // Clean speech 0.1–24.9: windows at 0.1 and 10.1, and a third moved back to 15–25.
        let starts = plan.windows.map(\.start)
        #expect(starts.count == 3)
        #expect(zip(starts, [0.1, 10.1, 15]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(plan.windows.allSatisfy { $0.start + VoiceRecognition.windowSeconds <= 25 })
        #expect(plan.windows.allSatisfy { $0.spans.allSatisfy { $0[0] >= 0 && $0[1] <= VoiceRecognition.windowSeconds } })
    }

    @Test func dropsWindowsWithTooLittleSpeech() {
        // Spans of 1.5 s every 20 s: no window reaches two seconds of speech.
        let segments = stride(from: 0.0, to: 200, by: 20).map { segment("speaker_1", $0, $0 + 1.7) }
        let plan = VoiceWindowPlanner.plan(segments: segments, duration: 220)
        #expect(plan.windows.isEmpty)
        #expect(plan.tooShort == ["speaker_1"])
    }

    @Test func capsWindowsPerSpeakerEvenlyAcrossTheMeeting() {
        let plan = VoiceWindowPlanner.plan(segments: [segment("speaker_1", 0, 600)], duration: 600, maximumWindows: 5)
        #expect(plan.windows.count == 5)
        #expect(plan.windows.first!.start < 1)
        #expect(plan.windows.last!.start > 580)
    }

    @Test func frameWeightsCoverTheSpeakersFrames() {
        let window = VoiceWindow(speaker: "speaker_1", start: 0, spans: [[0, 5], [7.5, 10]])
        let weights = window.frameWeights()
        #expect(weights.count == VoiceRecognition.maskFrames)
        #expect(weights[0] > 0.999)
        #expect(weights[VoiceRecognition.maskFrames - 1] > 0.999)
        let width = VoiceRecognition.windowSeconds / Double(VoiceRecognition.maskFrames)
        #expect(weights[Int(6 / width)] == 0)
        let covered = weights.reduce(0) { $0 + Double($1) } * width
        #expect(abs(covered - 7.5) < 0.02)
        #expect(weights.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func fingerprintIgnoresTextButNotTiming() throws {
        var meeting = Meeting(id: "m", title: "T", audioName: "a.wav", language: "auto", speakerCount: nil, duration: 60)
        meeting.segments = [segment("speaker_1", 0, 10)]
        let original = VoiceRecognition.fingerprint(of: meeting, modelRevision: "r")
        meeting.segments[0].text = "edited"
        #expect(VoiceRecognition.fingerprint(of: meeting, modelRevision: "r") == original)
        meeting.segments[0].speaker = "speaker_2"
        #expect(VoiceRecognition.fingerprint(of: meeting, modelRevision: "r") != original)
        meeting.segments[0].speaker = "speaker_1"
        #expect(VoiceRecognition.fingerprint(of: meeting, modelRevision: "other") != original)
    }
}

struct VoiceMatcherTests {
    @Test func aggregatesWindowsWeightedBySpeech() throws {
        let windows = [
            VoiceWindow(speaker: "speaker_1", start: 0, spans: [[0, 8]]),
            VoiceWindow(speaker: "speaker_1", start: 10, spans: [[0, 2]]),
            VoiceWindow(speaker: "speaker_2", start: 20, spans: [[0, 5]]),
        ]
        let prints = Voiceprint.aggregate(windows: windows, embeddings: [voice(0), voice(1), voice(2)])
        #expect(prints.map(\.speaker) == ["speaker_1", "speaker_2"])
        let first = try #require(prints.first)
        #expect(first.windows == 2)
        #expect(first.speechSeconds == 10)
        #expect(first.vector[0] > first.vector[1] * 3)
        #expect(abs(VoiceMath.dot(first.vector, first.vector) - 1) < 1e-5)
    }

    @Test func assignsConfidentMatchesAndLeavesTheRestAlone() {
        let samples = [
            VoiceSample(meetingID: "a", speaker: "speaker_1", profileID: "ada", vector: voice(0), speechSeconds: 60),
            VoiceSample(meetingID: "b", speaker: "speaker_1", profileID: "ada", vector: voice(0, blend: 5, amount: 0.2), speechSeconds: 60),
            VoiceSample(meetingID: "a", speaker: "speaker_2", profileID: "bo", vector: voice(1), speechSeconds: 60),
        ]
        var meeting = Meeting(id: "new", title: "T", audioName: "a.wav", language: "auto", speakerCount: nil, duration: 60)
        meeting.speakers = [
            "speaker_1": "Speaker 1", "speaker_2": "Speaker 2", "speaker_3": "Speaker 3",
            "speaker_4": "Speaker 4", "speaker_5": "Speaker 5", "speaker_unknown": "Unknown speaker",
        ]
        meeting.speakerProfiles = ["speaker_5": "bo"]
        let prints = MeetingVoiceprints(meetingID: "new", fingerprint: "f", modelRevision: "r", voiceprints: [
            Voiceprint(speaker: "speaker_1", vector: voice(0, blend: 6, amount: 0.1), speechSeconds: 30, windows: 3),
            // Two labels may belong to one person: MOSS sometimes splits a speaker.
            Voiceprint(speaker: "speaker_2", vector: voice(0, blend: 7, amount: 0.15), speechSeconds: 30, windows: 3),
            Voiceprint(speaker: "speaker_3", vector: voice(2), speechSeconds: 30, windows: 3),
            // Already linked by hand, so never reconsidered.
            Voiceprint(speaker: "speaker_5", vector: voice(0), speechSeconds: 30, windows: 3),
        ], tooShort: ["speaker_4"])
        let matcher = VoiceMatcher(samples: samples, scorer: .centroid)
        let matches = VoiceRule(scorer: .centroid, threshold: 0.6, margin: 0.1).match(prints, meeting: meeting, matcher: matcher)
        let decisions = Dictionary(uniqueKeysWithValues: matches.map { ($0.speaker, $0) })
        #expect(decisions.keys.sorted() == ["speaker_1", "speaker_2", "speaker_3", "speaker_4"])
        #expect(decisions["speaker_1"]?.decision == .assigned)
        #expect(decisions["speaker_1"]?.profileID == "ada")
        #expect(decisions["speaker_2"]?.decision == .assigned)
        #expect(decisions["speaker_2"]?.profileID == "ada")
        #expect(decisions["speaker_3"]?.decision == .unrecognized)
        #expect(decisions["speaker_4"]?.decision == .tooShort)
    }

    @Test func aCloseRunnerUpIsUncertain() {
        let rule = VoiceRule(scorer: .centroid, threshold: 0.5, margin: 0.1)
        let match = rule.decide(speaker: "s", candidates: [
            VoiceCandidate(profileID: "ada", score: 0.8), VoiceCandidate(profileID: "bo", score: 0.75),
        ])
        #expect(match.decision == .uncertain)
        #expect(match.runnerUpID == "bo")
    }

    @Test func onlyManualLinksTrain() {
        var meeting = Meeting(id: "m", title: "T", audioName: "a.wav", language: "auto", speakerCount: nil, duration: 60)
        meeting.speakerProfiles = ["speaker_1": "ada", "speaker_2": "bo"]
        meeting.autoSpeakerProfiles = ["speaker_2": 0.8]
        let prints = MeetingVoiceprints(meetingID: "m", fingerprint: "f", modelRevision: "r", voiceprints: [
            Voiceprint(speaker: "speaker_1", vector: voice(0), speechSeconds: 10, windows: 1),
            Voiceprint(speaker: "speaker_2", vector: voice(1), speechSeconds: 10, windows: 1),
            Voiceprint(speaker: "speaker_3", vector: voice(2), speechSeconds: 10, windows: 1),
        ], tooShort: [])
        #expect(VoiceSample.training(from: meeting, voiceprints: prints).map(\.profileID) == ["ada"])
    }

    @Test func nearestScorerUsesTheClosestSamples() {
        let samples = [
            VoiceSample(meetingID: "a", speaker: "s", profileID: "ada", vector: voice(0), speechSeconds: 10),
            VoiceSample(meetingID: "b", speaker: "s", profileID: "ada", vector: voice(3), speechSeconds: 10),
        ]
        let nearest = VoiceMatcher(samples: samples, scorer: .nearest).candidates(for: voice(0))
        let centroid = VoiceMatcher(samples: samples, scorer: .centroid).candidates(for: voice(0))
        #expect(abs(nearest[0].score - 0.5) < 1e-6)
        #expect(abs(centroid[0].score - 0.5.squareRoot()) < 1e-6)
        #expect(VoiceMatcher(samples: samples, scorer: .centroid).candidates(for: voice(0), excludingMeeting: "b")[0].score > 0.99)
    }
}

struct VoiceCalibrationTests {
    /// Four people across six meetings, plus one stranger who appears once.
    private func library() -> [VoiceSample] {
        var samples: [VoiceSample] = []
        for meeting in 0..<6 {
            for person in 0..<4 {
                samples.append(VoiceSample(
                    meetingID: "m\(meeting)", speaker: "speaker_\(person + 1)", profileID: "p\(person)",
                    vector: voice(person, blend: 10 + meeting, amount: 0.3), speechSeconds: 30
                ))
            }
        }
        samples.append(VoiceSample(meetingID: "m0", speaker: "speaker_5", profileID: "stranger",
                                   vector: voice(0, blend: 1, amount: 0.9), speechSeconds: 30))
        return samples
    }

    @Test func heldOutMeetingsAreScoredWithoutTheirOwnTags() {
        let trials = VoiceCalibration.trials(library(), scorer: .centroid)
        #expect(trials.count == 25)
        #expect(trials.filter(\.recognizable).count == 24)
        let stranger = trials.first { $0.truth == "stranger" }!
        #expect(!stranger.candidates.contains { $0.profileID == "stranger" })
    }

    @Test func choosesARuleThatMeetsThePrecisionTarget() {
        let result = VoiceCalibration.calibrate(library(), scorers: VoiceScorer.allCases)
        #expect(result.calibrated)
        #expect(result.metrics.precision >= VoiceCalibration.targetPrecision)
        #expect(result.metrics.correct == 24)
        // The stranger sits between two profiles; abstaining on it is the right answer.
        #expect(result.metrics.wrong == 0)
    }

    @Test func fallsBackWithoutRepeatSpeakers() {
        let samples = [
            VoiceSample(meetingID: "a", speaker: "s", profileID: "ada", vector: voice(0), speechSeconds: 10),
            VoiceSample(meetingID: "b", speaker: "s", profileID: "bo", vector: voice(1), speechSeconds: 10),
        ]
        let result = VoiceCalibration.calibrate(samples)
        #expect(!result.calibrated)
        #expect(result.rule == .fallback)
    }
}

struct LibraryAutoTagSummaryTests {
    private func outcome(_ id: String, applied: [String]) -> AutoTagOutcome {
        AutoTagOutcome(
            meetingID: id,
            matches: applied.map { VoiceMatch(speaker: $0, decision: .assigned, profileID: "ada", score: 0.9) },
            applied: applied, dryRun: false
        )
    }

    private func skip(_ title: String) -> AutoTagSkip {
        AutoTagSkip(id: title.lowercased(), title: title, reason: "This meeting's audio is missing.")
    }

    @Test func reportsTaggedSpeakersAndClearedSummaries() {
        let text = AutoTagOutcome.librarySummary(
            [outcome("a", applied: ["speaker_1", "speaker_2"]), outcome("b", applied: [])],
            skipped: [], clearedSummaries: 1
        )
        #expect(text == "Tagged 2 speakers in 1 meeting. 1 summary was cleared because speaker names changed.")
        #expect(AutoTagOutcome.librarySummary([], skipped: [], clearedSummaries: 0)
            == "No transcribed meetings have untagged speakers.")
    }

    @Test func namesASingleSkippedMeetingWithItsReason() {
        let text = AutoTagOutcome.librarySummary(
            [outcome("a", applied: [])], skipped: [skip("Old call")], clearedSummaries: 0
        )
        #expect(text == "No new speakers matched a profile confidently. Skipped “Old call”: This meeting's audio is missing.")
        // When every meeting was skipped, there is nothing else to say first.
        #expect(AutoTagOutcome.librarySummary([], skipped: [skip("Old call")], clearedSummaries: 0)
            == "Skipped “Old call”: This meeting's audio is missing.")
    }

    @Test func listsSeveralSkippedMeetingsBriefly() {
        let text = AutoTagOutcome.librarySummary(
            [outcome("a", applied: ["speaker_1"])],
            skipped: ["One", "Two", "Three", "Four", "Five"].map(skip), clearedSummaries: 0
        )
        #expect(text == "Tagged 1 speaker in 1 meeting. Skipped 5 meetings that couldn't be auto-tagged: "
            + "“One”, “Two”, “Three” and 2 more. Open one and choose Auto-Tag Speakers to see why.")
    }
}

struct VoiceModelSetupTests {
    @Test func theSpeakerModelIsASupportingModel() throws {
        let spec = try #require(SpeechCatalog.models[SpeechCatalog.speakerModel])
        #expect(spec.kind == .speaker)
        #expect(SpeechCatalog.transcriptionModels[SpeechCatalog.speakerModel] == nil)
        #expect(spec.files.keys.contains("Embedding.mlmodelc/weights/weight.bin"))
        #expect(spec.files.values.allSatisfy { $0.sha256?.count == 64 })
        #expect(spec.files.keys.allSatisfy(ModelInstaller.isSafeRelativePath))
    }

    @Test func manifestNamesCannotEscapeTheModelDirectory() {
        #expect(ModelInstaller.isSafeRelativePath("FBank.mlmodelc/weights/weight.bin"))
        for name in ["", "/etc/passwd", "../x", "a/../../x", "a//b", "./a", "a/", "a\\b"] {
            #expect(!ModelInstaller.isSafeRelativePath(name), "\(name)")
        }
    }

    @Test func embeddingsEventsAreValidatedAsAWhole() async throws {
        let good = (0..<VoiceRecognition.dimension).map { _ in 0.0625 }
        #expect(WorkerOutput.vectors([good, good])?.count == 2)
        #expect(WorkerOutput.vectors([good, Array(good.dropLast())]) == nil)
        #expect(WorkerOutput.vectors([good, good.map { _ in Double.nan }]) == nil)
        #expect(WorkerOutput.vectors("nope") == nil)

        let pipe = Pipe()
        let collector = WorkerOutput { _, _ in }
        let read = Task { await collector.read(from: pipe.fileHandleForReading) }
        let payload = try JSONSerialization.data(withJSONObject: ["type": "embeddings", "vectors": [good]])
        try pipe.fileHandleForWriting.write(contentsOf: Data("STILLNOTE_EVENT ".utf8) + payload + Data([10]))
        try pipe.fileHandleForWriting.close()
        await read.value
        #expect(await collector.embeddings?.count == 1)
    }
}
