import Foundation

/// Library navigation data only. Transcript, summary and notes belong to the detail loader.
public struct MeetingListItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let createdAt: String
    public let createdDate: Date
    public let startDate: Date
    public let duration: Double
    public let status: MeetingStatus
    public let hasVideo: Bool
    public let speakers: [String: String]
    public let starred: Bool
    public let tagIDs: [String]
    public let speakerCount: Int
    /// A line for the meeting list: the summary overview, or the first transcript line.
    public let snippet: String
    public let revision: Int64
    public let searchRevision: Int64

    /// `snippet` defaults to one drawn from `meeting`; the library index passes its own,
    /// because its copy of the document has no transcript or summary.
    public init(_ meeting: Meeting, revision: Int64 = 0, searchRevision: Int64 = 0, snippet: String? = nil) {
        id = meeting.id
        title = meeting.title
        createdAt = meeting.createdAt
        createdDate = meeting.createdDate
        startDate = meeting.startDate
        duration = meeting.duration
        status = meeting.status
        hasVideo = meeting.hasVideo
        speakers = meeting.speakers
        starred = meeting.starred
        tagIDs = meeting.tagIDs
        speakerCount = meeting.speakers.count
        self.snippet = snippet ?? Self.snippet(meeting)
        self.revision = revision
        self.searchRevision = searchRevision
    }
}

extension MeetingListItem {
    /// The same text the library index stores: the overview, else the first line, at most 160 characters.
    public static func snippet(_ meeting: Meeting) -> String {
        let overview = meeting.summary?.overview.trimmingCharacters(in: .whitespaces) ?? ""
        return String((overview.isEmpty ? meeting.segments.first?.text ?? "" : overview).prefix(160))
    }
}

public struct MeetingSnapshot: Sendable {
    public let meeting: Meeting
    public let item: MeetingListItem
}
