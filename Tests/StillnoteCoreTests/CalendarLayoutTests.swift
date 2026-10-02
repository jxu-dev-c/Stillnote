import Foundation
import Testing

@testable import StillnoteCore

@Suite struct CalendarLayoutTests {
    private static func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    let sunday = CalendarLayout(calendar: calendar(firstWeekday: 1))
    let monday = CalendarLayout(calendar: calendar(firstWeekday: 2))

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        sunday.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func monthGridStartsOnTheLocalesFirstWeekday() {
        // October 2026 begins on a Thursday.
        let sundayGrid = sunday.monthGrid(containing: date(2026, 10, 15))
        #expect(sundayGrid.first?.first == date(2026, 9, 27))
        #expect(sundayGrid.last?.last == date(2026, 10, 31))
        #expect(sundayGrid.count == 5)

        let mondayGrid = monday.monthGrid(containing: date(2026, 10, 15))
        #expect(mondayGrid.first?.first == date(2026, 9, 28))
        #expect(mondayGrid.last?.last == date(2026, 11, 1))
        #expect(mondayGrid.count == 5)
        #expect(mondayGrid.allSatisfy { $0.count == 7 })
    }

    @Test func monthGridUsesOnlyTheRowsTheMonthNeeds() {
        // February 2026 is exactly four Sunday-first weeks; August 2026 needs six.
        #expect(sunday.monthGrid(containing: date(2026, 2, 10)).count == 4)
        #expect(sunday.monthGrid(containing: date(2026, 8, 31)).count == 6)
    }

    @Test func weekDaysFollowTheFirstWeekday() {
        let thursday = date(2026, 10, 1, 15)
        #expect(sunday.days(.week, containing: thursday).first == date(2026, 9, 27))
        #expect(monday.days(.week, containing: thursday).first == date(2026, 9, 28))
        #expect(monday.days(.week, containing: thursday).count == 7)
        #expect(sunday.days(.day, containing: thursday) == [date(2026, 10, 1)])
        #expect(monday.orderedWeekdaySymbols.first == "Mon")
        #expect(sunday.orderedWeekdaySymbols.first == "Sun")
    }

    @Test func steppingCrossesMonthAndYearBoundaries() {
        #expect(sunday.step(date(2026, 12, 31), .day, by: 1) == date(2027, 1, 1))
        #expect(sunday.step(date(2026, 12, 29), .week, by: 1) == date(2027, 1, 5))
        #expect(sunday.step(date(2026, 1, 31), .month, by: 1) == date(2026, 2, 28))
        #expect(sunday.step(date(2026, 1, 15), .month, by: -1) == date(2025, 12, 15))
        #expect(sunday.interval(.month, containing: date(2026, 2, 10)).end == date(2026, 3, 1))
    }

    private func clock(_ hour: Int, _ minute: Int = 0) -> TimeInterval {
        TimeInterval(hour * 3600 + minute * 60)
    }

    @Test func disjointEventsEachTakeTheFullWidth() {
        let placements = CalendarLayout.placements([
            ("a", clock(9), 3600),
            ("b", clock(10), 1800),
        ])
        #expect(placements["a"] == .init(column: 0, columns: 1))
        #expect(placements["b"] == .init(column: 0, columns: 1))
    }

    @Test func overlappingEventsShareColumnsAcrossAChain() {
        // a overlaps b, and b overlaps c, so all three line up in one group. c starts after a
        // ends, so it reuses a's column rather than adding a third.
        let placements = CalendarLayout.placements([
            ("b", clock(9, 30), 3600),
            ("a", clock(9), 3600),
            ("c", clock(10), 1800),
            ("d", clock(13), 600),
        ])
        #expect(placements["a"] == .init(column: 0, columns: 2))
        #expect(placements["b"] == .init(column: 1, columns: 2))
        #expect(placements["c"] == .init(column: 0, columns: 2))
        #expect(placements["d"] == .init(column: 0, columns: 1))
    }

    @Test func nestedEventsAndZeroDurationsGetTheirOwnColumn() {
        // A zero-length meeting still occupies the minimum height, so the one starting five
        // minutes later must sit beside it.
        let placements = CalendarLayout.placements([
            ("long", clock(9), 7200),
            ("empty", clock(9, 30), 0),
            ("next", clock(9, 35), 600),
        ])
        #expect(placements["long"] == .init(column: 0, columns: 3))
        #expect(placements["empty"] == .init(column: 1, columns: 3))
        #expect(placements["next"] == .init(column: 2, columns: 3))
    }

    @Test func clockOffsetFollowsTheWallClockAcrossDaylightSaving() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Halifax")!
        let layout = CalendarLayout(calendar: calendar)
        func local(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        // March 8 is 23 hours long and November 1 is 25. Elapsed time from midnight would put
        // these at 8:00 and 10:00, and the late meeting below the end of the day.
        #expect(layout.clockOffset(local(3, 8, 9)) == clock(9))
        #expect(layout.clockOffset(local(11, 1, 9)) == clock(9))
        #expect(layout.clockOffset(local(11, 1, 23, 30)) == clock(23, 30))
        #expect(layout.clockOffset(local(6, 1, 0)) == 0)
    }

    @Test func startDatePrefersTheRecordedTimeAndEstimatesOlderRecordings() {
        let saved = "2026-10-01T10:00:00.000+00:00"
        var recording = Meeting(
            id: "r", title: "Sync", audioName: "recording.wav", language: "en", speakerCount: nil,
            duration: 1800, cleanup: MeetingCleanup(originalDuration: 1920, head: 60, tail: 60)
        )
        recording.createdAt = saved
        // Saved at 10:00 after 30 kept minutes and a trimmed one-minute tail.
        #expect(recording.startDate == Meeting.parseTimestamp("2026-10-01T09:29:00.000+00:00"))

        recording.recordedAt = "2026-10-01T09:31:00.000+00:00"
        #expect(recording.startDate == Meeting.parseTimestamp("2026-10-01T09:31:00.000+00:00"))

        var imported = Meeting(
            id: "i", title: "Call", audioName: "call.m4a", language: "en", speakerCount: nil, duration: 1800
        )
        imported.createdAt = saved
        #expect(imported.startDate == imported.createdDate)
    }
}
