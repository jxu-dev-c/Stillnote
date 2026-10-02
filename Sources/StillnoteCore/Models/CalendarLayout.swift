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

    /// Where `date` falls on a day's timeline, in seconds by the wall clock. Counting elapsed
    /// time from midnight would put a 9:00 meeting at 8:00 or 10:00 on a daylight-saving
    /// change, away from its hour label; the clock reading always matches the label.
    public func clockOffset(_ date: Date) -> TimeInterval {
        let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let hours = TimeInterval(time.hour ?? 0) * 3600
        let minutes = TimeInterval(time.minute ?? 0) * 60
        let seconds = TimeInterval(time.second ?? 0) + TimeInterval(time.nanosecond ?? 0) / 1e9
        return hours + minutes + seconds
    }

    /// The `clockOffset` range a meeting covers on its start day. The end comes from the real
    /// end time, so a meeting across a daylight-saving change ends at the clock time it
    /// actually finished. A meeting running past midnight is cut at the end of the day.
    public func clockSpan(start: Date, duration: TimeInterval) -> (start: TimeInterval, end: TimeInterval) {
        let top = clockOffset(start)
        let end = start.addingTimeInterval(max(duration, 0))
        let bottom = calendar.isDate(end, inSameDayAs: start) ? clockOffset(end) : 86_400
        // When clocks fall back, a short meeting can end at an earlier clock time than it began.
        return (top, max(bottom, top + Self.minimumEventDuration))
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
    /// line up. Each event takes the leftmost column that is free when it starts. Spans are
    /// `clockSpan`s, the same coordinates the timeline draws in.
    public static func placements(
        _ events: [(id: String, start: TimeInterval, end: TimeInterval)]
    ) -> [String: Placement] {
        typealias Span = (id: String, start: TimeInterval, end: TimeInterval)
        let spans: [Span] = events.map { event in
            let end: TimeInterval = max(event.end, event.start + minimumEventDuration)
            return (event.id, event.start, end)
        }
        let sorted = spans.sorted { (a: Span, b: Span) -> Bool in
            a.start == b.start ? a.end > b.end : a.start < b.start
        }

        var result: [String: Placement] = [:]
        var group: [(id: String, column: Int)] = []
        var columnEnds: [TimeInterval] = []
        var groupEnd = -TimeInterval.infinity

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
