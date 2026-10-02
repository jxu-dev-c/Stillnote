import Foundation

/// The ranges the meetings calendar can show, matching Calendar.app's Day, Week, and Month.
public enum CalendarSpan: String, CaseIterable, Identifiable, Sendable {
    case day, week, month

    public var id: String { rawValue }

    var component: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }
}

/// Date math for the meetings calendar. The calendar is injected so tests can pin the
/// first weekday and time zone instead of inheriting the machine's locale.
public struct CalendarLayout: Sendable {
    /// Calendar.app gives even a zero-length event enough height to read and click.
    public static let minimumEventDuration: TimeInterval = 15 * 60

    public var calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// The day, week, or month containing `date`.
    public func interval(_ span: CalendarSpan, containing date: Date) -> DateInterval {
        calendar.dateInterval(of: span.component, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
    }

    /// The same position one or more days, weeks, or months away.
    public func step(_ date: Date, _ span: CalendarSpan, by value: Int) -> Date {
        calendar.date(byAdding: span.component, value: value, to: date) ?? date
    }

    /// The day columns of a Day or Week view, starting on the locale's first weekday.
    public func days(_ span: CalendarSpan, containing date: Date) -> [Date] {
        switch span {
        case .day: return [calendar.startOfDay(for: date)]
        case .week: return days(from: interval(.week, containing: date).start, count: 7)
        case .month: return monthGrid(containing: date).flatMap { $0 }
        }
    }

    /// Whole weeks covering the month containing `date`, padded with the neighboring
    /// months' days so every row has seven. A month spans four to six rows.
    public func monthGrid(containing date: Date) -> [[Date]] {
        let month = interval(.month, containing: date)
        let lastDay = calendar.date(byAdding: .day, value: -1, to: month.end) ?? month.start
        var weekStart = interval(.week, containing: month.start).start
        var rows: [[Date]] = []
        while weekStart <= lastDay {
            rows.append(days(from: weekStart, count: 7))
            weekStart = calendar.date(byAdding: .weekOfYear, value: 1, to: weekStart) ?? month.end
        }
        return rows
    }

    /// Weekday symbols ordered to match the grid's columns.
    public var orderedWeekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func days(from start: Date, count: Int) -> [Date] {
        (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Where an event sits among the events it overlaps: `column` of `columns` equal slices.
    public struct Placement: Equatable, Sendable {
        public var column: Int
        public var columns: Int

        public init(column: Int, columns: Int) {
            self.column = column
            self.columns = columns
        }
    }

    /// Side-by-side columns for overlapping events, as Calendar.app lays out a busy day.
    /// Events that overlap directly or through a chain share one group, so their slices
    /// line up. Each event takes the leftmost column that is free when it starts.
    public static func placements(
        _ events: [(id: String, start: Date, duration: TimeInterval)]
    ) -> [String: Placement] {
        let sorted = events
            .map { (id: $0.id, start: $0.start, end: $0.start.addingTimeInterval(max($0.duration, minimumEventDuration))) }
            .sorted { $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start }

        var result: [String: Placement] = [:]
        var group: [(id: String, column: Int)] = []
        var columnEnds: [Date] = []
        var groupEnd = Date.distantPast

        func closeGroup() {
            for item in group {
                result[item.id] = Placement(column: item.column, columns: columnEnds.count)
            }
            group.removeAll()
            columnEnds.removeAll()
        }

        for event in sorted {
            if event.start >= groupEnd { closeGroup() }
            if let free = columnEnds.firstIndex(where: { $0 <= event.start }) {
                columnEnds[free] = event.end
                group.append((event.id, free))
            } else {
                columnEnds.append(event.end)
                group.append((event.id, columnEnds.count - 1))
            }
            groupEnd = max(groupEnd, event.end)
        }
        closeGroup()
        return result
    }
}
