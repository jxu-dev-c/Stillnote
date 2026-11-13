import Foundation

/// The JSON shapes `stillnote --json` prints. They are a deliberate, stable contract for the
/// published skill: the stored `Meeting` document keeps its legacy field names for the app's own
/// compatibility, and an agent should not have to know which of those are historical accidents.
/// `skills/stillnote/references/output.md` documents these.
public struct SpeakerLine: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Whether the name comes from a reusable speaker profile rather than this meeting alone.
    public var profile: Bool
    /// Present when Stillnote linked the profile by voice and nobody has confirmed it yet: the
    /// match's similarity, 0–1.
    public var voiceMatch: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, profile
        case voiceMatch = "voice_match"
    }

    public init(id: String, name: String, profile: Bool, voiceMatch: Double? = nil) {
        self.id = id
        self.name = name
        self.profile = profile
        self.voiceMatch = voiceMatch
    }
}

public struct TranscriptLine: Codable, Hashable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var speaker: String
    public var speakerName: String
    public var text: String

    enum CodingKeys: String, CodingKey {
        case id, start, end, speaker, text
        case speakerName = "speaker_name"
    }

    public init(_ segment: Segment, in meeting: Meeting) {
        id = segment.id
        start = segment.start
        end = segment.end
        speaker = segment.speaker
        speakerName = meeting.speakerName(segment.speaker)
        text = segment.text
    }
}

public struct MeetingPayload: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: String
    public var updatedAt: String
    public var duration: Double
    public var status: MeetingStatus
    public var stage: String
    public var error: String?
    public var language: String
    public var speakers: [SpeakerLine]
    public var segmentCount: Int
    public var summary: MeetingSummary?
    public var notes: String
    public var contextLinks: [ContextLink]
    public var cleanup: MeetingCleanup?
    public var hasVideo: Bool
    /// Names of the meeting's tags, in the order they were applied.
    public var tags: [String]
    /// Present only when the transcript was asked for.
    public var segments: [TranscriptLine]?

    enum CodingKeys: String, CodingKey {
        case id, title, duration, status, stage, error, language, speakers, summary, notes, cleanup, segments, tags
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case segmentCount = "segment_count"
        case contextLinks = "context_links"
        case hasVideo = "has_video"
    }

    public init(_ meeting: Meeting, includeSegments: Bool, speakerFilter: String? = nil, tags: [MeetingTag] = []) {
        id = meeting.id
        self.tags = MeetingTag.names(of: meeting.tagIDs, in: tags)
        title = meeting.title
        createdAt = meeting.createdAt
        updatedAt = meeting.updatedAt
        duration = meeting.duration
        status = meeting.status
        stage = meeting.stage
        error = meeting.error
        language = meeting.language
        speakers = meeting.orderedSpeakerIDs().map {
            SpeakerLine(
                id: $0, name: meeting.speakerName($0), profile: meeting.speakerProfiles[$0] != nil,
                voiceMatch: meeting.autoSpeakerProfiles[$0]
            )
        }
        segmentCount = meeting.segments.count
        summary = meeting.summary
        notes = meeting.notes
        contextLinks = meeting.contextLinks
        cleanup = meeting.cleanup
        hasVideo = meeting.hasVideo
        if includeSegments {
            let needle = speakerFilter?.lowercased()
            segments = meeting.segments.filter { segment in
                guard let needle, !needle.isEmpty else { return true }
                return meeting.speakerName(segment.speaker).lowercased().contains(needle)
                    || segment.speaker.lowercased().contains(needle)
            }.map { TranscriptLine($0, in: meeting) }
        }
    }
}

public struct ListPayload: Codable, Hashable, Sendable {
    public var count: Int
    public var meetings: [MeetingDigest]

    public init(_ meetings: [MeetingDigest]) {
        self.count = meetings.count
        self.meetings = meetings
    }
}

public struct SearchPayload: Codable, Hashable, Sendable {
    public var query: String
    public var count: Int
    public var results: [SearchResult]

    public init(query: String, results: [SearchResult]) {
        self.query = query
        self.count = results.count
        self.results = results
    }
}

public struct ReplaceChange: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var matches: Int
    public var segments: Int

    public init(id: String, title: String, outcome: ReplaceOutcome) {
        self.id = id
        self.title = title
        self.matches = outcome.matches
        self.segments = outcome.segments
    }
}

public struct ReplacePayload: Codable, Hashable, Sendable {
    public var find: String
    public var replacement: String
    public var dryRun: Bool
    public var matches: Int
    public var segments: Int
    public var meetings: [ReplaceChange]
    /// True when at least one meeting lost a summary drawn from the old text.
    public var summaryInvalidated: Bool

    enum CodingKeys: String, CodingKey {
        case find, replacement, matches, segments, meetings
        case dryRun = "dry_run"
        case summaryInvalidated = "summary_invalidated"
    }

    public init(
        find: String, replacement: String, dryRun: Bool, changes: [ReplaceChange],
        summaryInvalidated: Bool
    ) {
        self.find = find
        self.replacement = replacement
        self.dryRun = dryRun
        self.matches = changes.reduce(0) { $0 + $1.matches }
        self.segments = changes.reduce(0) { $0 + $1.segments }
        self.meetings = changes
        self.summaryInvalidated = summaryInvalidated
    }
}

public struct ExportPayload: Codable, Hashable, Sendable {
    public var id: String
    public var format: String
    public var path: String?
    public var text: String?

    public init(id: String, format: ExportFormat, path: String?, text: String?) {
        self.id = id
        self.format = format.rawValue
        self.path = path
        self.text = text
    }
}

public struct RecordPayload: Codable, Hashable, Sendable {
    public var recording: Bool
    public var state: String?
    public var sessionID: String?
    public var elapsed: Double?
    public var error: String?
    public var options: CaptureOptions?
    /// Set once a stop has saved the session as a meeting.
    public var meetingID: String?
    public var transcribing: Bool?

    enum CodingKeys: String, CodingKey {
        case recording, state, elapsed, error, options, transcribing
        case sessionID = "session_id"
        case meetingID = "meeting_id"
    }

    public init(session: RecordingSessionState?, meetingID: String? = nil, transcribing: Bool? = nil) {
        self.recording = session?.status.isActive ?? false
        self.state = session?.status.rawValue
        self.sessionID = session?.id
        self.elapsed = session?.elapsed
        self.error = session?.error
        self.options = session?.options
        self.meetingID = meetingID
        self.transcribing = transcribing
    }
}

public struct StatusPayload: Codable, Hashable, Sendable {
    public var running: Bool
    public var ready: Bool
    public var version: String?
    public var dataDirectory: String
    public var socket: String
    public var meetings: Int?
    public var speechReady: Bool?
    public var speechDetail: String?
    public var recording: Bool?
    public var transcribing: Bool?
    public var summaryProvider: String?
    public var captureAvailable: Bool?

    enum CodingKeys: String, CodingKey {
        case running, ready, version, socket, meetings, recording, transcribing
        case dataDirectory = "data_directory"
        case speechReady = "speech_ready"
        case speechDetail = "speech_detail"
        case summaryProvider = "summary_provider"
        case captureAvailable = "capture_available"
    }

    public init(
        running: Bool, ready: Bool, version: String? = nil, dataDirectory: String, socket: String,
        meetings: Int? = nil, speechReady: Bool? = nil, speechDetail: String? = nil,
        recording: Bool? = nil, transcribing: Bool? = nil, summaryProvider: String? = nil,
        captureAvailable: Bool? = nil
    ) {
        self.running = running
        self.ready = ready
        self.version = version
        self.dataDirectory = dataDirectory
        self.socket = socket
        self.meetings = meetings
        self.speechReady = speechReady
        self.speechDetail = speechDetail
        self.recording = recording
        self.transcribing = transcribing
        self.summaryProvider = summaryProvider
        self.captureAvailable = captureAvailable
    }
}

public struct DevicesPayload: Codable, Hashable, Sendable {
    public struct Device: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var available: Bool
    public var reason: String?
    public var microphones: [Device]
    public var displays: [Device]
    public var defaultDisplay: String?

    enum CodingKeys: String, CodingKey {
        case available, reason, microphones, displays
        case defaultDisplay = "default_display"
    }

    public init(_ capabilities: CaptureCapabilities) {
        available = capabilities.available
        reason = capabilities.reason
        microphones = capabilities.microphones.map { Device(id: $0.id, name: $0.name) }
        displays = capabilities.displays.map { Device(id: String($0.id), name: $0.name) }
        defaultDisplay = capabilities.defaultDisplayID.map(String.init)
    }
}

public struct TextPayload: Codable, Hashable, Sendable {
    public var id: String?
    public var text: String

    public init(id: String? = nil, text: String) {
        self.id = id
        self.text = text
    }
}

public struct HelpPayload: Codable, Hashable, Sendable {
    public var commands: [CommandSpec]
    /// Options accepted by every command, kept in help JSON so documentation checks can use the
    /// same catalog as the parser.
    public var globalValueOptions: [String]
    public var globalBooleanOptions: [String]

    enum CodingKeys: String, CodingKey {
        case commands
        case globalValueOptions = "global_value_options"
        case globalBooleanOptions = "global_boolean_options"
    }

    public init(
        commands: [CommandSpec] = CommandCatalog.commands,
        globalValueOptions: [String] = CommandCatalog.globalValues,
        globalBooleanOptions: [String] = CommandCatalog.globalBooleans
    ) {
        self.commands = commands
        self.globalValueOptions = globalValueOptions
        self.globalBooleanOptions = globalBooleanOptions
    }
}

/// One meeting a speaker profile is linked to, and which of that meeting's speakers it names.
public struct SpeakerAppearance: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: String
    public var speaker: String

    enum CodingKeys: String, CodingKey {
        case id, title, speaker
        case createdAt = "created_at"
    }

    public init(id: String, title: String, createdAt: String, speaker: String) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.speaker = speaker
    }
}

public struct SpeakerProfilePayload: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Empty when not recorded.
    public var email: String
    public var phone: String
    public var meetingCount: Int
    /// Present on `speaker show` and on changes; omitted from `speaker list`.
    public var meetings: [SpeakerAppearance]?

    enum CodingKeys: String, CodingKey {
        case id, name, email, phone, meetings
        case meetingCount = "meeting_count"
    }

    public init(_ profile: SpeakerProfile, appearances: [SpeakerAppearance], includeMeetings: Bool) {
        id = profile.id
        name = profile.name
        email = profile.email
        phone = profile.phone
        meetingCount = Set(appearances.map(\.id)).count
        meetings = includeMeetings ? appearances : nil
    }
}

public struct SpeakerListPayload: Codable, Hashable, Sendable {
    public var count: Int
    public var speakers: [SpeakerProfilePayload]

    public init(_ speakers: [SpeakerProfilePayload]) {
        self.count = speakers.count
        self.speakers = speakers
    }
}

/// `speaker voices`: what Learn Voices produced. Voiceprints themselves are never printed.
public struct VoiceStatusPayload: Codable, Hashable, Sendable {
    public var learned: Bool
    public var learnedAt: String?
    public var profiles: Int
    public var meetings: Int
    public var samples: Int
    public var skippedMeetings: Int
    /// False when too few people appear in more than one meeting to measure accuracy.
    public var calibrated: Bool
    /// Share of held-out matches that named the right profile.
    public var precision: Double?
    /// Share of recognizable held-out speakers that were tagged correctly.
    public var coverage: Double?
    public var scorer: String?
    public var threshold: Double?
    public var margin: Double?
    public var autoTagAfterTranscription: Bool

    enum CodingKeys: String, CodingKey {
        case learned, profiles, meetings, samples, calibrated, precision, coverage, scorer, threshold, margin
        case learnedAt = "learned_at"
        case skippedMeetings = "skipped_meetings"
        case autoTagAfterTranscription = "auto_tag_after_transcription"
    }

    public init(_ model: VoiceModel?, settings: AppSettings) {
        learned = model != nil
        learnedAt = model?.learnedAt
        profiles = model?.profileCount ?? 0
        meetings = model?.meetingCount ?? 0
        samples = model?.sampleCount ?? 0
        skippedMeetings = model?.skippedMeetings ?? 0
        calibrated = model?.calibrated ?? false
        precision = model.flatMap { $0.calibrated ? $0.metrics.precision : nil }
        coverage = model.flatMap { $0.calibrated ? $0.metrics.coverage : nil }
        scorer = model?.rule.scorer.rawValue
        threshold = model?.rule.threshold
        margin = model?.rule.margin
        autoTagAfterTranscription = settings.speakerRecognition.autoTagAfterTranscription
    }
}

/// One label's auto-tag decision, with profile names resolved.
public struct AutoTagMatchPayload: Codable, Hashable, Sendable {
    public var speaker: String
    /// `assigned`, `uncertain`, `unrecognized`, or `too_short`.
    public var decision: String
    /// Whether this run linked the profile. Always false for a dry run.
    public var applied: Bool
    public var profile: String?
    public var profileName: String?
    public var score: Double?
    public var runnerUp: String?
    public var runnerUpName: String?
    public var runnerUpScore: Double?

    enum CodingKeys: String, CodingKey {
        case speaker, decision, applied, profile, score
        case profileName = "profile_name"
        case runnerUp = "runner_up"
        case runnerUpName = "runner_up_name"
        case runnerUpScore = "runner_up_score"
    }

    public init(_ match: VoiceMatch, applied: Bool, names: [String: String]) {
        speaker = match.speaker
        decision = match.decision.rawValue
        self.applied = applied
        profile = match.profileID
        profileName = match.profileID.flatMap { names[$0] }
        score = match.score
        runnerUp = match.runnerUpID
        runnerUpName = match.runnerUpID.flatMap { names[$0] }
        runnerUpScore = match.runnerUpScore
    }
}

public struct AutoTagMeetingPayload: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var matches: [AutoTagMatchPayload]
    public var tagged: Int
    public var summaryCleared: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, matches, tagged
        case summaryCleared = "summary_cleared"
    }

    public init(_ outcome: AutoTagOutcome, title: String, summaryCleared: Bool, names: [String: String]) {
        id = outcome.meetingID
        self.title = title
        matches = outcome.matches.map {
            AutoTagMatchPayload($0, applied: outcome.applied.contains($0.speaker), names: names)
        }
        tagged = outcome.applied.count
        self.summaryCleared = summaryCleared
    }
}

/// `speaker autotag`: one entry per meeting considered.
public struct AutoTagPayload: Codable, Hashable, Sendable {
    public var dryRun: Bool
    public var tagged: Int
    public var meetings: [AutoTagMeetingPayload]
    /// Meetings `--all` could not process, with the reason. A single named meeting fails the
    /// command instead, so this is empty then.
    public var skipped: [AutoTagSkip]

    enum CodingKeys: String, CodingKey {
        case meetings, tagged, skipped
        case dryRun = "dry_run"
    }

    public init(dryRun: Bool, meetings: [AutoTagMeetingPayload], skipped: [AutoTagSkip] = []) {
        self.dryRun = dryRun
        self.meetings = meetings
        self.skipped = skipped
        tagged = meetings.reduce(0) { $0 + $1.tagged }
    }
}

/// One meeting carrying a tag, for `tag show`.
public struct TaggedMeeting: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: String
    public var status: MeetingStatus
    public var hasSummary: Bool
    /// Every tag on the meeting, including the one shown.
    public var tags: [String]

    enum CodingKeys: String, CodingKey {
        case id, title, status, tags
        case createdAt = "created_at"
        case hasSummary = "has_summary"
    }

    public init(_ meeting: Meeting, tags: [MeetingTag]) {
        id = meeting.id
        title = meeting.title
        createdAt = meeting.createdAt
        status = meeting.status
        hasSummary = meeting.summary != nil
        self.tags = MeetingTag.names(of: meeting.tagIDs, in: tags)
    }
}

public struct TagPayload: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var color: TagColor
    public var meetingCount: Int
    /// Present on `tag show` and on changes; omitted from `tag list`.
    public var meetings: [TaggedMeeting]?

    enum CodingKeys: String, CodingKey {
        case id, name, color, meetings
        case meetingCount = "meeting_count"
    }

    public init(_ tag: MeetingTag, meetings: [Meeting], allTags: [MeetingTag], includeMeetings: Bool) {
        id = tag.id
        name = tag.name
        color = tag.color
        let tagged = TagQuery.meetings(tagged: tag.id, in: meetings)
        meetingCount = tagged.count
        self.meetings = includeMeetings ? tagged.map { TaggedMeeting($0, tags: allTags) } : nil
    }
}

public struct TagListPayload: Codable, Hashable, Sendable {
    public var count: Int
    public var tags: [TagPayload]

    public init(_ tags: [TagPayload]) {
        self.count = tags.count
        self.tags = tags
    }
}

/// `tag auto`: the tags OpenAI chose for each meeting, and which of them were new.
public struct TagSuggestionPayload: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// Every tag OpenAI chose, by name.
    public var suggested: [String]
    /// The chosen tags the meeting didn't already carry. Saved unless this was a dry run.
    public var added: [String]
    /// Every tag on the meeting afterwards (or as it would be, on a dry run).
    public var tags: [String]
    /// Why the meeting was skipped or failed, if it was.
    public var error: String?

    public init(id: String, title: String, suggested: [String], added: [String], tags: [String], error: String? = nil) {
        self.id = id
        self.title = title
        self.suggested = suggested
        self.added = added
        self.tags = tags
        self.error = error
    }
}

public struct TagAutoPayload: Codable, Hashable, Sendable {
    public var dryRun: Bool
    public var model: String
    public var count: Int
    public var meetings: [TagSuggestionPayload]

    enum CodingKeys: String, CodingKey {
        case model, count, meetings
        case dryRun = "dry_run"
    }

    public init(dryRun: Bool, model: String, meetings: [TagSuggestionPayload]) {
        self.dryRun = dryRun
        self.model = model
        self.count = meetings.count
        self.meetings = meetings
    }
}
