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
    public let revision: Int64
    public let searchRevision: Int64

    public init(_ meeting: Meeting, revision: Int64 = 0, searchRevision: Int64 = 0) {
        id = meeting.id
        title = meeting.title
        createdAt = meeting.createdAt
        createdDate = meeting.createdDate
        startDate = meeting.startDate
        duration = meeting.duration
        status = meeting.status
        hasVideo = meeting.hasVideo
        speakers = meeting.speakers
        self.revision = revision
        self.searchRevision = searchRevision
    }
}

public struct MeetingSnapshot: Sendable {
    public let meeting: Meeting
    public let item: MeetingListItem
}
