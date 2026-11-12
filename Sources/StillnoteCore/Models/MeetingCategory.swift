import Foundation

/// The colors a category can use. Stored as a name rather than a value so the app can map
/// each one to the system color for the current appearance.
public enum CategoryColor: String, Codable, CaseIterable, Identifiable, Sendable {
    // The first four are the design's accents, in the order new categories take them.
    case blue, purple, orange, green, pink, teal, yellow, red, gray

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    /// A value written by a newer build reads as gray rather than failing the category.
    public init(from decoder: Decoder) throws {
        self = CategoryColor(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .gray
    }

    /// The first color no category uses yet, or the next one in rotation once all are taken.
    public static func next(after used: [CategoryColor]) -> CategoryColor {
        let palette = allCases.filter { $0 != .gray }
        return palette.first { !used.contains($0) } ?? palette[used.count % palette.count]
    }
}

/// How the sidebar orders categories.
public enum CategorySort: String, CaseIterable, Identifiable, Sendable {
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

/// A user-made group of meetings, shown in the sidebar. Meetings refer to it by id.
public struct MeetingCategory: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var color: CategoryColor
    /// The category's place in the sidebar when sorted manually.
    public var position: Int

    public init(id: String = UUID().uuidString.lowercased(), name: String, color: CategoryColor, position: Int) {
        self.id = id
        self.name = name
        self.color = color
        self.position = position
    }

    public static func sorted(
        _ categories: [MeetingCategory], by sort: CategorySort, counts: [String: Int] = [:]
    ) -> [MeetingCategory] {
        let byName: (MeetingCategory, MeetingCategory) -> Bool = {
            switch $0.name.localizedStandardCompare($1.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: $0.position < $1.position
            }
        }
        switch sort {
        case .manual:
            return categories.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
        case .name:
            return categories.sorted(by: byName)
        case .count:
            return categories.sorted {
                let (left, right) = (counts[$0.id, default: 0], counts[$1.id, default: 0])
                return left != right ? left > right : byName($0, $1)
            }
        }
    }
}
