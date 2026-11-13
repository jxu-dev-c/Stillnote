import Foundation

/// Lightweight sidebar archive metadata. Retention is exactly five 24-hour days.
public struct DeletedMeeting: Codable, Identifiable, Sendable {
    public static let retention: TimeInterval = 5 * 24 * 60 * 60
    public let id: String
    public let title: String
    public let deletedAt: Double
    public var expiresAt: Date { Date(timeIntervalSince1970: deletedAt + Self.retention) }
}
