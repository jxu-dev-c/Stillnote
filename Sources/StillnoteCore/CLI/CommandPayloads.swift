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

    public init(id: String, name: String, profile: Bool) {
        self.id = id
        self.name = name
        self.profile = profile
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
    /// Present only when the transcript was asked for.
    public var segments: [TranscriptLine]?

    enum CodingKeys: String, CodingKey {
        case id, title, duration, status, stage, error, language, speakers, summary, notes, cleanup, segments
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case segmentCount = "segment_count"
        case contextLinks = "context_links"
        case hasVideo = "has_video"
    }

    public init(_ meeting: Meeting, includeSegments: Bool, speakerFilter: String? = nil) {
        id = meeting.id
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
                id: $0, name: meeting.speakerName($0), profile: meeting.speakerProfiles[$0] != nil
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

    public init(commands: [CommandSpec] = CommandCatalog.commands) {
        self.commands = commands
    }
}
