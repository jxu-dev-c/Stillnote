import Foundation

/// Transcript line produced by MOSS or edited by the user.
public struct Segment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var start: Double
    public var end: Double
    public var speaker: String
    public var text: String

    public init(id: String, start: Double, end: Double, speaker: String, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

public struct ContextLink: Codable, Hashable, Identifiable, Sendable {
    public var url: String
    public var title: String

    public var id: String { url }

    public init(url: String, title: String = "") {
        self.url = url
        self.title = title
    }
}

public struct ActionItem: Codable, Hashable, Identifiable, Sendable {
    public var text: String
    public var owner: String?
    public var due: String?

    public var id: String { "\(text)|\(owner ?? "")|\(due ?? "")" }

    public init(text: String, owner: String? = nil, due: String? = nil) {
        self.text = text
        self.owner = owner
        self.due = due
    }
}

public struct MeetingSummary: Codable, Hashable, Sendable {
    public var overview: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var provider: String
    public var model: String
    public var generatedAt: String

    enum CodingKeys: String, CodingKey {
        case overview
        case keyPoints = "key_points"
        case decisions
        case actionItems = "action_items"
        case provider
        case model
        case generatedAt = "generated_at"
    }

    public init(
        overview: String, keyPoints: [String], decisions: [String], actionItems: [ActionItem],
        provider: String, model: String, generatedAt: String
    ) {
        self.overview = overview
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.provider = provider
        self.model = model
        self.generatedAt = generatedAt
    }
}

public enum MeetingStatus: String, Codable, Sendable {
    case ready, transcribing, transcribed, summarizing, complete, error

    /// Processing states that block edits and deletion, matching storage.BUSY.
    public var isBusy: Bool { self == .transcribing || self == .summarizing }
}

/// One meeting, stored as a single JSON document exactly as the Python app wrote it,
/// so an existing stillnote.sqlite3 opens without migration.
public struct Meeting: Codable, Identifiable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var createdAt: String
    public var updatedAt: String
    public var duration: Double
    public var status: MeetingStatus
    public var progress: Double
    public var stage: String
    public var error: String?
    public var audioName: String
    public var audioURL: String
    public var videoURL: String?
    public var summaryIncludeVideoPath: Bool
    public var language: String
    public var speakerCount: Int?
    public var speakers: [String: String]
    public var segments: [Segment]
    public var summary: MeetingSummary?
    public var notes: String
    public var contextLinks: [ContextLink]

    enum CodingKeys: String, CodingKey {
        case id, title, duration, status, progress, stage, error, language, speakers, segments, summary, notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case audioName = "audio_name"
        case audioURL = "audio_url"
        case videoURL = "video_url"
        case summaryIncludeVideoPath = "summary_include_video_path"
        case speakerCount = "speaker_count"
        case contextLinks = "context_links"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(String.self, forKey: .createdAt)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        status = try values.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .ready
        progress = try values.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        stage = try values.decodeIfPresent(String.self, forKey: .stage) ?? ""
        error = try values.decodeIfPresent(String.self, forKey: .error)
        audioName = try values.decodeIfPresent(String.self, forKey: .audioName) ?? "recording.wav"
        audioURL = try values.decodeIfPresent(String.self, forKey: .audioURL) ?? ""
        // Legacy rows predate these fields; storage.py applied the same defaults on read.
        videoURL = try values.decodeIfPresent(String.self, forKey: .videoURL)
        summaryIncludeVideoPath = try values.decodeIfPresent(Bool.self, forKey: .summaryIncludeVideoPath) ?? false
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        speakerCount = try values.decodeIfPresent(Int.self, forKey: .speakerCount)
        speakers = try values.decodeIfPresent([String: String].self, forKey: .speakers) ?? [:]
        segments = try values.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        summary = try values.decodeIfPresent(MeetingSummary.self, forKey: .summary)
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        contextLinks = try values.decodeIfPresent([ContextLink].self, forKey: .contextLinks) ?? []
    }

    public init(
        id: String, title: String, audioName: String, language: String, speakerCount: Int?,
        duration: Double, videoName: String? = nil, error: String? = nil
    ) {
        let timestamp = Meeting.now()
        self.id = id
        self.title = title
        self.createdAt = timestamp
        self.updatedAt = timestamp
        self.duration = duration
        self.status = .ready
        self.progress = 0
        self.stage = "Ready to transcribe"
        self.error = error
        self.audioName = audioName
        self.audioURL = "/api/meetings/\(id)/audio"
        self.videoURL = videoName == nil ? nil : "/api/meetings/\(id)/video"
        self.summaryIncludeVideoPath = false
        self.language = language
        self.speakerCount = speakerCount
        self.speakers = [:]
        self.segments = []
        self.summary = nil
        self.notes = ""
        self.contextLinks = []
    }

    public var hasVideo: Bool { videoURL != nil }

    public static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        // Python emits +00:00; ISO8601DateFormatter emits Z. Both parse, and only
        // string ordering matters for sorting, which is unaffected by the suffix.
        return formatter.string(from: Date()).replacingOccurrences(of: "Z", with: "+00:00")
    }

    public var createdDate: Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: createdAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: createdAt) ?? .distantPast
    }

    /// Display name for a segment's speaker id, falling back to the raw id.
    public func speakerName(_ id: String) -> String { speakers[id] ?? id }

    public func orderedSpeakerIDs() -> [String] { speakers.keys.sorted() }
}
