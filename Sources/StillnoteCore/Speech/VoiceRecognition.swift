import CryptoKit
import Foundation

/// Constants of the speaker-embedding model. WeSpeaker ResNet34 (pyannote community-1)
/// embeds one ten-second window of 16 kHz audio, with a per-frame mask selecting whose
/// speech inside that window the embedding should describe.
public enum VoiceRecognition {
    public static let windowSeconds = 10.0
    public static let windowSamples = 160_000
    /// The mask resolution the model accepts. Frames cover the window uniformly; the model
    /// resamples them to its own pooling resolution internally.
    public static let maskFrames = 589
    public static let dimension = 256
    /// MOSS's catch-all label mixes everyone it could not attribute, so it never has a voice.
    public static let unknownSpeaker = "speaker_unknown"

    /// Identifies the voiceprint inputs: segment timing and speaker labels, the recording's
    /// length, and the model. Text edits leave it unchanged; retranscription, splitting and
    /// speaker or timing edits change it.
    public static func fingerprint(of meeting: Meeting, modelRevision: String) -> String {
        var hasher = SHA256()
        func add(_ text: String) { hasher.update(data: Data(text.utf8)) }
        add("v1|\(modelRevision)|\(Int((meeting.duration * 1000).rounded()))")
        for segment in meeting.segments {
            add("|\(Int((segment.start * 1000).rounded())),\(Int((segment.end * 1000).rounded())),\(segment.speaker)")
        }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// One ten-second stretch of the recording and where in it the target speaker talks.
public struct VoiceWindow: Codable, Hashable, Sendable {
    public var speaker: String
    /// Seconds on the stored recording's timeline.
    public var start: Double
    /// Speech of `speaker`, as `[start, end]` pairs relative to `start`.
    public var spans: [[Double]]

    public init(speaker: String, start: Double, spans: [[Double]]) {
        self.speaker = speaker
        self.start = start
        self.spans = spans
    }

    public var speechSeconds: Double {
        spans.reduce(0) { $0 + max(0, $1[1] - $1[0]) }
    }

    /// The model's per-frame weights: the fraction of each frame the speaker covers.
    public func frameWeights() -> [Float] {
        let count = VoiceRecognition.maskFrames
        let width = VoiceRecognition.windowSeconds / Double(count)
        var weights = [Float](repeating: 0, count: count)
        for span in spans where span.count == 2 {
            let lower = max(0, span[0]), upper = min(VoiceRecognition.windowSeconds, span[1])
            guard upper > lower else { continue }
            let first = max(0, Int(lower / width)), last = min(count - 1, Int(upper / width))
            guard first <= last else { continue }
            for frame in first...last {
                let frameStart = Double(frame) * width
                let overlap = min(upper, frameStart + width) - max(lower, frameStart)
                if overlap > 0 { weights[frame] = min(1, weights[frame] + Float(overlap / width)) }
            }
        }
        return weights
    }
}

public struct VoiceWindowPlan: Sendable {
    public var windows: [VoiceWindow]
    /// Clean speech per label after overlap removal, including labels without windows.
    public var speechSeconds: [String: Double]
    /// Labels with too little clean speech to embed.
    public var tooShort: [String]
}

/// Chooses which audio represents each diarized label. MOSS timestamps are sentence-level,
/// so the edges of every span are trimmed and speech that overlaps another label is removed:
/// a voiceprint must describe one person.
public enum VoiceWindowPlanner {
    public static let edgeTrim = 0.1
    public static let minimumSpan = 0.5
    public static let minimumWindowSpeech = 2.0
    public static let minimumSpeakerSpeech = 3.0
    public static let maximumWindowsPerSpeaker = 24

    public static func plan(
        segments: [Segment], duration: Double, maximumWindows: Int = maximumWindowsPerSpeaker
    ) -> VoiceWindowPlan {
        let limit = duration > 0 ? duration : (segments.map(\.end).max() ?? 0)
        var bySpeaker: [String: [(Double, Double)]] = [:]
        for segment in segments where segment.start.isFinite && segment.end.isFinite {
            let start = max(0, segment.start), end = min(limit, segment.end)
            guard end > start else { continue }
            bySpeaker[segment.speaker, default: []].append((start, end))
        }
        var windows: [VoiceWindow] = []
        var speech: [String: Double] = [:]
        var tooShort: [String] = []
        for speaker in bySpeaker.keys.sorted() where speaker != VoiceRecognition.unknownSpeaker {
            let own = merge(bySpeaker[speaker]!)
            let others = merge(bySpeaker.filter { $0.key != speaker }.flatMap(\.value))
            let clean = subtract(own, others).compactMap { span -> (Double, Double)? in
                let trimmed = (span.0 + edgeTrim, span.1 - edgeTrim)
                return trimmed.1 - trimmed.0 >= minimumSpan ? trimmed : nil
            }
            let total = clean.reduce(0) { $0 + $1.1 - $1.0 }
            speech[speaker] = total
            let packed = total >= minimumSpeakerSpeech
                ? spread(pack(speaker: speaker, spans: clean, duration: limit), limit: maximumWindows)
                : []
            if packed.isEmpty { tooShort.append(speaker) }
            windows.append(contentsOf: packed)
        }
        return VoiceWindowPlan(windows: windows, speechSeconds: speech, tooShort: tooShort)
    }

    /// Groups consecutive spans into ten-second windows. A window that would run past the end
    /// of a recording at least ten seconds long is moved back inside it, so the model never
    /// sees padding.
    static func pack(speaker: String, spans: [(Double, Double)], duration: Double) -> [VoiceWindow] {
        let length = VoiceRecognition.windowSeconds
        var result: [VoiceWindow] = []
        var cursor = 0.0
        while let next = spans.first(where: { $0.1 > cursor }) {
            var start = max(cursor, next.0)
            if duration >= length, start + length > duration { start = duration - length }
            let end = start + length
            let inside: [[Double]] = spans.compactMap { span in
                let lower = max(span.0, start), upper = min(span.1, end)
                return upper - lower > 0 ? [max(0, lower - start), min(length, upper - start)] : nil
            }
            let window = VoiceWindow(speaker: speaker, start: start, spans: inside)
            if window.speechSeconds >= minimumWindowSpeech { result.append(window) }
            guard end > cursor else { break }
            cursor = end
        }
        return result
    }

    /// Keeps at most `limit` windows, evenly spaced across the meeting.
    static func spread(_ windows: [VoiceWindow], limit: Int) -> [VoiceWindow] {
        guard windows.count > limit, limit > 0 else { return windows }
        guard limit > 1 else { return [windows[windows.count / 2]] }
        return (0..<limit).map { index in
            windows[Int((Double(index) * Double(windows.count - 1) / Double(limit - 1)).rounded())]
        }
    }

    static func merge(_ spans: [(Double, Double)]) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        for span in spans.sorted(by: { $0.0 < $1.0 }) {
            if let last = result.last, span.0 <= last.1 {
                result[result.count - 1].1 = max(last.1, span.1)
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// `spans` minus `removed`; both sorted and merged.
    static func subtract(_ spans: [(Double, Double)], _ removed: [(Double, Double)]) -> [(Double, Double)] {
        var result: [(Double, Double)] = []
        for span in spans {
            var start = span.0
            for cut in removed where cut.1 > start && cut.0 < span.1 {
                if cut.0 > start { result.append((start, cut.0)) }
                start = max(start, cut.1)
            }
            if span.1 > start { result.append((start, span.1)) }
        }
        return result
    }
}

/// A diarized label's voice in one meeting.
public struct Voiceprint: Codable, Hashable, Sendable {
    public var speaker: String
    /// Unit length.
    public var vector: [Float]
    public var speechSeconds: Double
    public var windows: Int

    public init(speaker: String, vector: [Float], speechSeconds: Double, windows: Int) {
        self.speaker = speaker
        self.vector = vector
        self.speechSeconds = speechSeconds
        self.windows = windows
    }

    /// The speech-weighted mean of each label's window embeddings, normalized.
    public static func aggregate(windows: [VoiceWindow], embeddings: [[Float]]) -> [Voiceprint] {
        precondition(windows.count == embeddings.count)
        var sums: [String: [Float]] = [:]
        var speech: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for (window, embedding) in zip(windows, embeddings) {
            guard let unit = VoiceMath.normalized(embedding) else { continue }
            let weight = Float(window.speechSeconds)
            var sum = sums[window.speaker] ?? [Float](repeating: 0, count: unit.count)
            guard sum.count == unit.count else { continue }
            for index in unit.indices { sum[index] += unit[index] * weight }
            sums[window.speaker] = sum
            speech[window.speaker, default: 0] += window.speechSeconds
            counts[window.speaker, default: 0] += 1
        }
        return sums.keys.sorted().compactMap { speaker in
            guard let vector = VoiceMath.normalized(sums[speaker]!) else { return nil }
            return Voiceprint(
                speaker: speaker, vector: vector, speechSeconds: speech[speaker] ?? 0, windows: counts[speaker] ?? 0
            )
        }
    }
}

/// A meeting's voiceprints and the inputs they were computed from.
public struct MeetingVoiceprints: Codable, Hashable, Sendable {
    public var meetingID: String
    public var fingerprint: String
    public var modelRevision: String
    public var voiceprints: [Voiceprint]
    /// Labels with too little clean speech to recognize.
    public var tooShort: [String]

    public init(meetingID: String, fingerprint: String, modelRevision: String, voiceprints: [Voiceprint], tooShort: [String]) {
        self.meetingID = meetingID
        self.fingerprint = fingerprint
        self.modelRevision = modelRevision
        self.voiceprints = voiceprints
        self.tooShort = tooShort
    }

    enum CodingKeys: String, CodingKey {
        case voiceprints
        case meetingID = "meeting_id"
        case fingerprint
        case modelRevision = "model_revision"
        case tooShort = "too_short"
    }
}

enum VoiceMath {
    static func normalized(_ vector: [Float]) -> [Float]? {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm.isFinite, norm > 1e-6 else { return nil }
        return vector.map { $0 / norm }
    }

    static func dot(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return -1 }
        var total: Float = 0
        for index in lhs.indices { total += lhs[index] * rhs[index] }
        return total
    }
}

/// A manually confirmed voice: one label in one meeting linked to a profile.
public struct VoiceSample: Hashable, Sendable {
    public var meetingID: String
    public var speaker: String
    public var profileID: String
    public var vector: [Float]
    public var speechSeconds: Double

    public init(meetingID: String, speaker: String, profileID: String, vector: [Float], speechSeconds: Double) {
        self.meetingID = meetingID
        self.speaker = speaker
        self.profileID = profileID
        self.vector = vector
        self.speechSeconds = speechSeconds
    }

    /// Samples from labels linked by hand. Labels Stillnote matched itself are left out until
    /// the user confirms them, so a wrong match cannot teach the next one.
    public static func training(from meeting: Meeting, voiceprints: MeetingVoiceprints) -> [VoiceSample] {
        voiceprints.voiceprints.compactMap { print in
            guard let profile = meeting.speakerProfiles[print.speaker],
                  meeting.autoSpeakerProfiles[print.speaker] == nil
            else { return nil }
            return VoiceSample(
                meetingID: meeting.id, speaker: print.speaker, profileID: profile,
                vector: print.vector, speechSeconds: print.speechSeconds
            )
        }
    }
}

public enum VoiceScorer: String, Codable, Sendable, CaseIterable {
    /// Cosine against the mean of a profile's samples.
    case centroid
    /// Mean cosine of the three most similar samples.
    case nearest
}

public struct VoiceCandidate: Hashable, Sendable {
    public var profileID: String
    public var score: Double
}

/// Scores voiceprints against the profiles of confirmed samples.
public struct VoiceMatcher: Sendable {
    public let scorer: VoiceScorer
    private let samples: [VoiceSample]

    public init(samples: [VoiceSample], scorer: VoiceScorer) {
        self.samples = samples.filter { !$0.vector.isEmpty }
        self.scorer = scorer
    }

    public var profileIDs: Set<String> { Set(samples.map(\.profileID)) }

    /// Every profile's score, best first. `excludingMeeting` leaves one meeting's samples out,
    /// which calibration uses to score a meeting as if it had never been tagged.
    public func candidates(for vector: [Float], excludingMeeting: String? = nil) -> [VoiceCandidate] {
        var grouped: [String: [VoiceSample]] = [:]
        for sample in samples where sample.meetingID != excludingMeeting {
            grouped[sample.profileID, default: []].append(sample)
        }
        return grouped.map { profile, members in
            VoiceCandidate(profileID: profile, score: score(vector, members))
        }.sorted { $0.score == $1.score ? $0.profileID < $1.profileID : $0.score > $1.score }
    }

    private func score(_ vector: [Float], _ members: [VoiceSample]) -> Double {
        switch scorer {
        case .centroid:
            var sum = [Float](repeating: 0, count: vector.count)
            for member in members where member.vector.count == vector.count {
                for index in sum.indices { sum[index] += member.vector[index] }
            }
            guard let centroid = VoiceMath.normalized(sum) else { return -1 }
            return Double(VoiceMath.dot(vector, centroid))
        case .nearest:
            let best = members.map { Double(VoiceMath.dot(vector, $0.vector)) }.sorted(by: >).prefix(3)
            return best.isEmpty ? -1 : best.reduce(0, +) / Double(best.count)
        }
    }
}

/// What auto-tagging decided for one label.
public struct VoiceMatch: Codable, Hashable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case assigned, uncertain, unrecognized, tooShort = "too_short"
    }

    public var speaker: String
    public var decision: Decision
    public var profileID: String?
    public var score: Double?
    public var runnerUpID: String?
    public var runnerUpScore: Double?

    enum CodingKeys: String, CodingKey {
        case speaker, decision, score
        case profileID = "profile_id"
        case runnerUpID = "runner_up_id"
        case runnerUpScore = "runner_up_score"
    }
}

/// The learned decision rule and how well it did against the user's own tags.
public struct VoiceRule: Codable, Hashable, Sendable {
    public var scorer: VoiceScorer
    public var threshold: Double
    public var margin: Double

    public init(scorer: VoiceScorer, threshold: Double, margin: Double) {
        self.scorer = scorer
        self.threshold = threshold
        self.margin = margin
    }

    /// Used when there is not enough tagged data to calibrate. Measured on a library of 338
    /// tagged voices across 83 meetings, this rule was right 97.7% of the time and tagged 79%.
    public static let fallback = VoiceRule(scorer: .nearest, threshold: 0.75, margin: 0.15)

    public func decide(speaker: String, candidates: [VoiceCandidate]) -> VoiceMatch {
        guard let best = candidates.first else {
            return VoiceMatch(speaker: speaker, decision: .unrecognized)
        }
        let second = candidates.dropFirst().first
        let gap = best.score - (second?.score ?? -1)
        let decision: VoiceMatch.Decision = best.score < threshold
            ? .unrecognized
            : (gap < margin ? .uncertain : .assigned)
        return VoiceMatch(
            speaker: speaker, decision: decision, profileID: best.profileID, score: best.score,
            runnerUpID: second?.profileID, runnerUpScore: second?.score
        )
    }

    /// Decides every label in a meeting that has no profile yet.
    public func match(
        _ voiceprints: MeetingVoiceprints, meeting: Meeting, matcher: VoiceMatcher
    ) -> [VoiceMatch] {
        let pending = meeting.orderedSpeakerIDs().filter {
            $0 != VoiceRecognition.unknownSpeaker && meeting.speakerProfiles[$0] == nil
        }
        let prints = Dictionary(voiceprints.voiceprints.map { ($0.speaker, $0) }, uniquingKeysWith: { first, _ in first })
        return pending.map { speaker in
            guard let print = prints[speaker] else { return VoiceMatch(speaker: speaker, decision: .tooShort) }
            return decide(speaker: speaker, candidates: matcher.candidates(for: print.vector))
        }
    }
}

public struct VoiceMetrics: Codable, Hashable, Sendable {
    /// Held-out labels whose profile appears in another meeting, so could be recognized.
    public var recognizable: Int
    /// Held-out labels whose profile appears nowhere else; the right answer is to abstain.
    public var strangers: Int
    public var correct: Int
    public var wrong: Int
    public var abstained: Int

    public var assigned: Int { correct + wrong }
    public var precision: Double { assigned == 0 ? 0 : Double(correct) / Double(assigned) }
    /// Share of recognizable labels tagged correctly.
    public var coverage: Double { recognizable == 0 ? 0 : Double(correct) / Double(recognizable) }

    enum CodingKeys: String, CodingKey { case recognizable, strangers, correct, wrong, abstained }
}

/// Leave-one-meeting-out calibration: every tagged meeting is scored against profiles built
/// from all the others, and the rule that tags the most labels while staying at the target
/// precision wins.
public enum VoiceCalibration {
    public static let targetPrecision = 0.97

    public struct Trial: Sendable {
        public var truth: String
        public var recognizable: Bool
        public var candidates: [VoiceCandidate]
    }

    public struct Result: Sendable {
        public var rule: VoiceRule
        public var metrics: VoiceMetrics
        /// False when there were too few repeat speakers to measure, and the fallback rule applies.
        public var calibrated: Bool
    }

    public static func trials(_ samples: [VoiceSample], scorer: VoiceScorer) -> [Trial] {
        let matcher = VoiceMatcher(samples: samples, scorer: scorer)
        let meetingsByProfile = Dictionary(grouping: samples, by: \.profileID).mapValues { Set($0.map(\.meetingID)) }
        return samples.map { sample in
            let elsewhere = meetingsByProfile[sample.profileID, default: []].subtracting([sample.meetingID])
            return Trial(
                truth: sample.profileID, recognizable: !elsewhere.isEmpty,
                candidates: matcher.candidates(for: sample.vector, excludingMeeting: sample.meetingID)
            )
        }
    }

    public static func evaluate(_ trials: [Trial], rule: VoiceRule) -> VoiceMetrics {
        var metrics = VoiceMetrics(
            recognizable: trials.filter(\.recognizable).count, strangers: trials.filter { !$0.recognizable }.count,
            correct: 0, wrong: 0, abstained: 0
        )
        for trial in trials {
            let match = rule.decide(speaker: "", candidates: trial.candidates)
            if match.decision != .assigned {
                metrics.abstained += 1
            } else if match.profileID == trial.truth {
                metrics.correct += 1
            } else {
                metrics.wrong += 1
            }
        }
        return metrics
    }

    public static func calibrate(_ samples: [VoiceSample], scorers: [VoiceScorer] = VoiceScorer.allCases) -> Result {
        var best: (rule: VoiceRule, metrics: VoiceMetrics, meetsTarget: Bool, f1: Double)?
        for scorer in scorers {
            let trials = trials(samples, scorer: scorer)
            guard trials.contains(where: \.recognizable) else { continue }
            for thresholdStep in stride(from: 20, through: 95, by: 1) {
                for margin in [0.0, 0.02, 0.04, 0.06, 0.08, 0.1, 0.15, 0.2] {
                    let rule = VoiceRule(scorer: scorer, threshold: Double(thresholdStep) / 100, margin: margin)
                    let metrics = evaluate(trials, rule: rule)
                    guard metrics.assigned > 0 else { continue }
                    let meets = metrics.precision >= targetPrecision
                    let f1 = 2 * metrics.precision * metrics.coverage / max(1e-9, metrics.precision + metrics.coverage)
                    let better: Bool
                    if let current = best {
                        if meets != current.meetsTarget {
                            better = meets
                        } else if meets {
                            // Most labels tagged; on a tie, the stricter rule.
                            better = metrics.correct > current.metrics.correct
                                || (metrics.correct == current.metrics.correct && metrics.wrong < current.metrics.wrong)
                        } else {
                            better = f1 > current.f1 + 1e-12
                        }
                    } else {
                        better = true
                    }
                    if better { best = (rule, metrics, meets, f1) }
                }
            }
        }
        guard let best else {
            return Result(
                rule: .fallback,
                metrics: VoiceMetrics(recognizable: 0, strangers: samples.count, correct: 0, wrong: 0, abstained: samples.count),
                calibrated: false
            )
        }
        return Result(rule: best.rule, metrics: best.metrics, calibrated: true)
    }
}

/// What Learn Voices produced: the decision rule calibrated on the user's own tags, and how
/// it performed. The voices themselves stay in the `voiceprints` table.
public struct VoiceModel: Codable, Hashable, Sendable {
    public var modelRevision: String
    public var learnedAt: String
    public var rule: VoiceRule
    public var calibrated: Bool
    public var metrics: VoiceMetrics
    public var profileCount: Int
    public var sampleCount: Int
    public var meetingCount: Int
    /// Tagged meetings whose voices could not be read, such as ones whose audio is missing.
    public var skippedMeetings: Int

    public init(
        modelRevision: String, learnedAt: String, rule: VoiceRule, calibrated: Bool, metrics: VoiceMetrics,
        profileCount: Int, sampleCount: Int, meetingCount: Int, skippedMeetings: Int
    ) {
        self.modelRevision = modelRevision
        self.learnedAt = learnedAt
        self.rule = rule
        self.calibrated = calibrated
        self.metrics = metrics
        self.profileCount = profileCount
        self.sampleCount = sampleCount
        self.meetingCount = meetingCount
        self.skippedMeetings = skippedMeetings
    }

    enum CodingKeys: String, CodingKey {
        case rule, calibrated, metrics
        case modelRevision = "model_revision"
        case learnedAt = "learned_at"
        case profileCount = "profile_count"
        case sampleCount = "sample_count"
        case meetingCount = "meeting_count"
        case skippedMeetings = "skipped_meetings"
    }
}

/// What one auto-tag run decided for a meeting.
public struct AutoTagOutcome: Codable, Hashable, Sendable {
    public var meetingID: String
    public var matches: [VoiceMatch]
    /// Labels this run linked. Empty for a dry run.
    public var applied: [String]
    public var dryRun: Bool

    public init(meetingID: String, matches: [VoiceMatch], applied: [String], dryRun: Bool) {
        self.meetingID = meetingID
        self.matches = matches
        self.applied = applied
        self.dryRun = dryRun
    }

    /// Labels heard clearly enough to compare that matched no profile confidently.
    public var unrecognized: Int { matches.filter { $0.decision == .unrecognized || $0.decision == .uncertain }.count }
    public var tooShort: Int { matches.filter { $0.decision == .tooShort }.count }

    /// One line for the interface, such as "Matched 2 speakers by voice. 1 wasn't recognized."
    public var summary: String {
        func speakers(_ count: Int) -> String { count == 1 ? "1 speaker" : "\(count) speakers" }
        let matched = dryRun ? matches.filter { $0.decision == .assigned }.count : applied.count
        if matches.isEmpty { return "Every speaker already has a profile." }
        if matched == 0 {
            return unrecognized == 0
                ? (tooShort == 1 ? "The untagged speaker has too little clear speech to recognize."
                    : "The untagged speakers have too little clear speech to recognize.")
                : "No untagged speakers matched a profile confidently."
        }
        let remaining = unrecognized + tooShort
        let lead = "Matched \(speakers(matched)) by voice."
        guard remaining > 0 else { return lead }
        return lead + (remaining == 1 ? " 1 wasn't recognized." : " \(remaining) weren't recognized.")
    }

    enum CodingKeys: String, CodingKey {
        case matches, applied
        case meetingID = "meeting_id"
        case dryRun = "dry_run"
    }

    /// The line Settings shows after Auto-Tag All Meetings, naming any meeting it skipped.
    public static func librarySummary(
        _ outcomes: [AutoTagOutcome], skipped: [AutoTagSkip], clearedSummaries: Int
    ) -> String {
        let tagged = outcomes.reduce(0) { $0 + $1.applied.count }
        let changed = outcomes.filter { !$0.applied.isEmpty }.count
        var parts: [String] = []
        if tagged > 0 {
            parts.append("Tagged \(tagged) \(tagged == 1 ? "speaker" : "speakers") in \(changed) \(changed == 1 ? "meeting" : "meetings").")
        } else if !outcomes.isEmpty {
            parts.append("No new speakers matched a profile confidently.")
        } else if skipped.isEmpty {
            parts.append("No transcribed meetings have untagged speakers.")
        }
        if clearedSummaries > 0 {
            parts.append("\(clearedSummaries) \(clearedSummaries == 1 ? "summary was" : "summaries were") cleared because speaker names changed.")
        }
        if let only = skipped.first, skipped.count == 1 {
            parts.append("Skipped “\(only.title)”: \(only.reason)")
        } else if !skipped.isEmpty {
            let named = skipped.prefix(3).map { "“\($0.title)”" }.joined(separator: ", ")
            let more = skipped.count > 3 ? " and \(skipped.count - 3) more" : ""
            parts.append("Skipped \(skipped.count) meetings that couldn't be auto-tagged: \(named)\(more). "
                + "Open one and choose Auto-Tag Speakers to see why.")
        }
        return parts.joined(separator: " ")
    }
}

/// A meeting a library-wide auto-tag could not process, and why.
public struct AutoTagSkip: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var reason: String

    public init(id: String, title: String, reason: String) {
        self.id = id
        self.title = title
        self.reason = reason
    }
}
