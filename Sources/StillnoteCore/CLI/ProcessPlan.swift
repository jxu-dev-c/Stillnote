import Foundation

/// Where `stillnote process` picks a meeting up.
public enum ProcessStage: String, Codable, Hashable, Sendable {
    /// No transcript yet: split if long, then transcribe, auto-tag, summarize, and name.
    case transcribe
    /// The transcript is there: summarize, then name.
    case summarize
}

/// What `stillnote process` does, or would do, with one meeting.
public struct ProcessStep: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var stage: ProcessStage
    /// How many meetings a split turns this one into; 1 when it stays whole.
    public var parts: Int
    /// Whether a title is requested once the summary is saved.
    public var named: Bool
    /// The meetings actually queued: the split parts, or the meeting itself. Empty for a dry run.
    public var queued: [String]

    enum CodingKeys: String, CodingKey {
        case id, title, stage, parts, named, queued
    }

    public init(id: String, title: String, stage: ProcessStage, parts: Int, named: Bool, queued: [String] = []) {
        self.id = id
        self.title = title
        self.stage = stage
        self.parts = parts
        self.named = named
        self.queued = queued
    }
}

public struct ProcessSkip: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var reason: String

    public init(id: String, title: String, reason: String) {
        self.id = id
        self.title = title
        self.reason = reason
    }
}

/// `stillnote process`: one step per meeting taken on, and the ones it could not take on.
public struct ProcessPayload: Codable, Hashable, Sendable {
    public var dryRun: Bool
    public var meetings: [ProcessStep]
    public var skipped: [ProcessSkip]

    enum CodingKeys: String, CodingKey {
        case meetings, skipped
        case dryRun = "dry_run"
    }

    public init(dryRun: Bool, meetings: [ProcessStep], skipped: [ProcessSkip] = []) {
        self.dryRun = dryRun
        self.meetings = meetings
        self.skipped = skipped
    }
}

/// Decides, without touching anything, which meetings `stillnote process` takes on and where
/// each one resumes. The app carries the plan out with the same calls as Stop, Transcribe &
/// Summarize.
public enum ProcessPlan {
    /// What `--all` takes on without `--status`: recordings never transcribed, and transcripts
    /// never summarized. Failed meetings are retried only when asked for with `--status error`,
    /// so a recording with no speech is not transcribed again on every sweep.
    public static let defaultStatuses: [MeetingStatus] = [.ready, .transcribed]
    public static let allowedStatuses: [MeetingStatus] = [.ready, .transcribed, .error]

    /// Where `meeting` resumes, or why it cannot be processed.
    public static func stage(for meeting: Meeting) throws -> ProcessStage {
        if meeting.status.isBusy {
            throw CLIError.busy("'\(meeting.title)' is \(meeting.status.rawValue). Wait for it to finish.")
        }
        if meeting.status == .complete {
            throw CLIError.usage(
                "'\(meeting.title)' is already summarized. Run 'stillnote name \(meeting.id) --allow-remote' "
                    + "to retitle it, or 'stillnote summarize' to summarize it again."
            )
        }
        return meeting.segments.isEmpty ? .transcribe : .summarize
    }

    public static func step(
        _ meeting: Meeting, splitThresholdMinutes: Int, split: Bool, name: Bool
    ) throws -> ProcessStep {
        let stage = try stage(for: meeting)
        var parts = 1
        if split, stage == .transcribe, RecordingSplit.eligible(meeting, thresholdMinutes: splitThresholdMinutes) {
            parts = Int(ceil(meeting.duration / RecordingSplit.partSeconds))
        }
        return ProcessStep(id: meeting.id, title: meeting.title, stage: stage, parts: parts, named: name)
    }

    /// The meetings `--all` takes on: those with one of `statuses`, narrowed by `filter`'s dates
    /// and limit, newest first.
    public static func candidates(
        _ meetings: [Meeting], statuses: [MeetingStatus], filter: MeetingFilter
    ) -> [Meeting] {
        var filter = filter
        filter.status = nil
        return MeetingQuery.filter(meetings.filter { statuses.contains($0.status) }, filter)
    }

    /// `--status` for `process`: one of `allowedStatuses`, or the defaults when absent.
    public static func statuses(_ raw: String?) throws -> [MeetingStatus] {
        guard let raw else { return defaultStatuses }
        guard let status = MeetingStatus(rawValue: raw.lowercased()), allowedStatuses.contains(status) else {
            let known = allowedStatuses.map(\.rawValue).joined(separator: ", ")
            throw CLIError.usage("'process --status' takes one of: \(known).")
        }
        return [status]
    }
}
