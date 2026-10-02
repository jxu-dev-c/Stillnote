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

    private func event(_ id: String, _ start: TimeInterval, _ duration: TimeInterval) -> (String, TimeInterval, TimeInterval) {
        (id, start, start + duration)
    }

    private static let halifax: CalendarLayout = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Halifax")!
        return CalendarLayout(calendar: calendar)
    }()

    private func halifax(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Self.halifax.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func disjointEventsEachTakeTheFullWidth() {
        let placements = CalendarLayout.placements([
            event("a", clock(9), 3600),
            event("b", clock(10), 1800),
        ])
        #expect(placements["a"] == .init(column: 0, columns: 1))
        #expect(placements["b"] == .init(column: 0, columns: 1))
    }

    @Test func overlappingEventsShareColumnsAcrossAChain() {
        // a overlaps b, and b overlaps c, so all three line up in one group. c starts after a
        // ends, so it reuses a's column rather than adding a third.
        let placements = CalendarLayout.placements([
            event("b", clock(9, 30), 3600),
            event("a", clock(9), 3600),
            event("c", clock(10), 1800),
            event("d", clock(13), 600),
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
            event("long", clock(9), 7200),
            event("empty", clock(9, 30), 0),
            event("next", clock(9, 35), 600),
        ])
        #expect(placements["long"] == .init(column: 0, columns: 3))
        #expect(placements["empty"] == .init(column: 1, columns: 3))
        #expect(placements["next"] == .init(column: 2, columns: 3))
    }

    @Test func clockOffsetFollowsTheWallClockAcrossDaylightSaving() {
        let layout = Self.halifax
        // March 8 is 23 hours long and November 1 is 25. Elapsed time from midnight would put
        // these at 8:00 and 10:00, and the late meeting below the end of the day.
        #expect(layout.clockOffset(halifax(3, 8, 9)) == clock(9))
        #expect(layout.clockOffset(halifax(11, 1, 9)) == clock(9))
        #expect(layout.clockOffset(halifax(11, 1, 23, 30)) == clock(23, 30))
        #expect(layout.clockOffset(halifax(6, 1, 0)) == 0)
    }

    @Test func spansAcrossAClockChangeEndAtTheRealEndTime() {
        let layout = Self.halifax
        // Spring forward: an hour from 1:30 ends at 3:30, so it overlaps a 3:00 meeting.
        let spring = layout.clockSpan(start: halifax(3, 8, 1, 30), duration: 3600)
        #expect(spring.start == clock(1, 30) && spring.end == clock(3, 30))
        let afterJump = layout.clockSpan(start: halifax(3, 8, 3), duration: 1800)
        let placements = CalendarLayout.placements([
            ("crossing", spring.start, spring.end), ("next", afterJump.start, afterJump.end),
        ])
        #expect(placements["crossing"] == .init(column: 0, columns: 2))
        #expect(placements["next"] == .init(column: 1, columns: 2))

        // Fall back: clocks return from 2:00 to 1:00, so 90 minutes from 0:30 ends at 1:00.
        let fall = layout.clockSpan(start: halifax(11, 1, 0, 30), duration: 5400)
        #expect(fall.start == clock(0, 30) && fall.end == clock(1))
        // 20 minutes from the first 1:50 ends at the second 1:10, before it began by the clock.
        // It keeps the minimum height rather than collapsing.
        let first = halifax(11, 1, 0, 30).addingTimeInterval(80 * 60)
        let repeated = layout.clockSpan(start: first, duration: 1200)
        #expect(repeated.start == clock(1, 50))
        #expect(repeated.end == clock(1, 50) + CalendarLayout.minimumEventDuration)
        // A meeting past midnight stops at the end of its start day.
        let late = layout.clockSpan(start: halifax(6, 1, 23, 30), duration: 3600)
        #expect(late.end == clock(24))
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

    @Test func anImportNamedLikeARecordingStaysAtItsImportTime() throws {
        var imported = try Meeting.imported(
            id: "i", from: URL(fileURLWithPath: "/tmp/recording.wav"), title: "", language: "en",
            speakerCount: nil, duration: 3600
        )
        imported.createdAt = "2026-10-01T00:15:00.000+00:00"
        #expect(imported.source == .import)
        #expect(imported.startDate == imported.createdDate)

        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(imported))
        #expect(decoded.source == .import)
        #expect(decoded.startDate == imported.createdDate)
    }
}
