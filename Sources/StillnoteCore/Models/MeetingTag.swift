import Foundation

/// The colors a tag can use. Stored as a name rather than a value so the app can map
/// each one to the system color for the current appearance.
public enum TagColor: String, Codable, CaseIterable, Identifiable, Sendable {
    // The first four are the design's accents, in the order new tags take them.
    case blue, purple, orange, green, pink, teal, yellow, red, gray

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    /// A value written by a newer build reads as gray rather than failing the tag.
    public init(from decoder: Decoder) throws {
        self = TagColor(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .gray
    }

    /// The first color no tag uses yet, or the next one in rotation once all are taken.
    public static func next(after used: [TagColor]) -> TagColor {
        let palette = allCases.filter { $0 != .gray }
        return palette.first { !used.contains($0) } ?? palette[used.count % palette.count]
    }
}

/// How the sidebar orders tags.
public enum TagSort: String, CaseIterable, Identifiable, Sendable {
    case manual, name, count

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .manual: "Manual"
        case .name: "Name"
        case .count: "Meeting Count"
        }
    }
}

/// A user-made label for meetings, shown in the sidebar. A meeting can carry several, by id.
/// Tags are stored in the `categories` table, the name they had when a meeting held only one.
public struct MeetingTag: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var color: TagColor
    /// The tag's place in the sidebar when sorted manually.
    public var position: Int

    public init(id: String = UUID().uuidString.lowercased(), name: String, color: TagColor, position: Int) {
        self.id = id
        self.name = name
        self.color = color
        self.position = position
    }

    public static func sorted(
        _ tags: [MeetingTag], by sort: TagSort, counts: [String: Int] = [:]
    ) -> [MeetingTag] {
        let byName: (MeetingTag, MeetingTag) -> Bool = {
            switch $0.name.localizedStandardCompare($1.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0.position < $1.position
            }
        }
        switch sort {
        case .manual:
            return tags.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
        case .name:
            return tags.sorted(by: byName)
        case .count:
            return tags.sorted {
                let (left, right) = (counts[$0.id, default: 0], counts[$1.id, default: 0])
                return left != right ? left > right : byName($0, $1)
            }
        }
    }

    /// Names for `ids` in their own order, skipping ids with no tag left.
    public static func names(of ids: [String], in tags: [MeetingTag]) -> [String] {
        ids.compactMap { id in tags.first { $0.id == id }?.name }
    }
}
