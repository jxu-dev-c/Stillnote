import Foundation
import Testing

@testable import StillnoteCore

@Suite struct MeetingReminderTests {
    let teams = MeetingApps.match(bundleID: "com.microsoft.teams2")!
    let chrome = MeetingApps.match(bundleID: "com.google.Chrome")!
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let on = MeetingReminderPolicy.Context(enabled: true, isRecording: false)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test func catalogMatchesHelpersAndIgnoresOtherApps() {
        #expect(teams.name == "Microsoft Teams")
        #expect(MeetingApps.match(bundleID: "com.microsoft.teams2.helper") == teams)
        #expect(MeetingApps.match(bundleID: "com.google.Chrome.helper") == chrome)
        #expect(MeetingApps.match(bundleID: "company.thebrowser.browser.helper")?.name == "Arc")
        #expect(MeetingApps.match(bundleID: "com.apple.WebKit.GPU")?.id == "com.apple.Safari")
        #expect(MeetingApps.match(bundleID: "us.zoom.xos")?.name == "Zoom")
        // A shared prefix is not a nested identifier.
        #expect(MeetingApps.match(bundleID: "com.google.Chromecast") == nil)
        #expect(MeetingApps.match(bundleID: "com.apple.VoiceMemos") == nil)
        #expect(MeetingApps.match(bundleID: "") == nil)
    }

    @Test func waitsForTheMicrophoneToSettleBeforeShowing() {
        var policy = MeetingReminderPolicy()
        #expect(policy.update(active: [teams], now: at(0), context: on) == nil)
        #expect(policy.nextDeadline == at(MeetingReminderPolicy.settleDelay))
        #expect(policy.update(active: [teams], now: at(1), context: on) == nil)
        #expect(policy.update(active: [teams], now: at(2), context: on) == .show(teams))
        #expect(policy.showing == teams)
        #expect(policy.nextDeadline == at(2 + MeetingReminderPolicy.displayDuration))
    }

    @Test func aBriefProbeNeverShows() {
        var policy = MeetingReminderPolicy()
        #expect(policy.update(active: [teams], now: at(0), context: on) == nil)
        #expect(policy.update(active: [], now: at(1), context: on) == nil)
        #expect(policy.update(active: [], now: at(5), context: on) == nil)
        #expect(policy.nextDeadline == nil)
    }

    @Test func neverShowsWhileRecordingOrDisabled() {
        var recording = MeetingReminderPolicy()
        let busy = MeetingReminderPolicy.Context(enabled: true, isRecording: true)
        #expect(recording.update(active: [teams], now: at(0), context: busy) == nil)
        #expect(recording.update(active: [teams], now: at(5), context: busy) == nil)
        // A meeting that was already being recorded does not prompt once recording stops.
        #expect(recording.update(active: [teams], now: at(10), context: on) == nil)
        #expect(recording.nextDeadline == nil)

        var disabled = MeetingReminderPolicy()
        let off = MeetingReminderPolicy.Context(enabled: false, isRecording: false)
        #expect(disabled.update(active: [teams], now: at(0), context: off) == nil)
        #expect(disabled.update(active: [teams], now: at(5), context: off) == nil)
        #expect(disabled.nextDeadline == nil)
    }

    @Test func remindsForTheAppThatSettledFirst() {
        var policy = MeetingReminderPolicy()
        #expect(policy.update(active: [chrome], now: at(0), context: on) == nil)
        #expect(policy.update(active: [chrome, teams], now: at(1), context: on) == nil)
        #expect(policy.update(active: [chrome, teams], now: at(3), context: on) == .show(chrome))
    }

    @Test func hidesWhenTheMeetingEndsARecordingStartsRemindersTurnOffOrItExpires() {
        var released = MeetingReminderPolicy()
        _ = released.update(active: [teams], now: at(0), context: on)
        #expect(released.update(active: [teams], now: at(2), context: on) == .show(teams))
        #expect(released.update(active: [], now: at(3), context: on) == .hide)
        #expect(released.showing == nil)

        var recording = MeetingReminderPolicy()
        _ = recording.update(active: [teams], now: at(0), context: on)
        #expect(recording.update(active: [teams], now: at(2), context: on) == .show(teams))
        let busy = MeetingReminderPolicy.Context(enabled: true, isRecording: true)
        #expect(recording.update(active: [teams], now: at(3), context: busy) == .hide)

        var disabled = MeetingReminderPolicy()
        _ = disabled.update(active: [teams], now: at(0), context: on)
        #expect(disabled.update(active: [teams], now: at(2), context: on) == .show(teams))
        let off = MeetingReminderPolicy.Context(enabled: false, isRecording: false)
        #expect(disabled.update(active: [teams], now: at(3), context: off) == .hide)

        var expiring = MeetingReminderPolicy()
        _ = expiring.update(active: [teams], now: at(0), context: on)
        #expect(expiring.update(active: [teams], now: at(2), context: on) == .show(teams))
        #expect(expiring.update(active: [teams], now: at(61), context: on) == nil)
        #expect(expiring.update(active: [teams], now: at(62), context: on) == .hide)
        #expect(expiring.update(active: [teams], now: at(200), context: on) == nil)
        #expect(expiring.nextDeadline == nil)
    }

    @Test func remindsOncePerMeetingAndAgainAfterALongBreak() {
        var policy = MeetingReminderPolicy()
        _ = policy.update(active: [teams], now: at(0), context: on)
        #expect(policy.update(active: [teams], now: at(2), context: on) == .show(teams))
        // Closing the reminder, like answering it, handles this meeting.
        policy.dismiss()
        #expect(policy.showing == nil)
        #expect(policy.nextDeadline == nil)
        #expect(policy.update(active: [teams], now: at(10), context: on) == nil)
        // Muting and unmuting briefly releases the microphone; that is the same meeting.
        #expect(policy.update(active: [], now: at(30), context: on) == nil)
        #expect(policy.update(active: [teams], now: at(40), context: on) == nil)
        #expect(policy.update(active: [teams], now: at(45), context: on) == nil)
        // A minute away from the microphone makes the next use a new meeting.
        #expect(policy.update(active: [], now: at(100), context: on) == nil)
        #expect(policy.update(active: [teams], now: at(160), context: on) == nil)
        #expect(policy.update(active: [teams], now: at(162), context: on) == .show(teams))
    }

    @Test func settingsAreOptInAndPersist() async throws {
        #expect(AppSettings().meetingReminders.enabled == false)
        #expect(AppSettings.migrating(from: [:]).settings.meetingReminders == MeetingReminderSettings())
        let migrated = AppSettings.migrating(from: ["meeting_reminders": ["enabled": true]])
        #expect(migrated.settings.meetingReminders == MeetingReminderSettings(enabled: true))
        let legacy = Data(#"{"transcription":{"model":"moss-0.9b","language":"auto"},"summary":{"provider":"codex","model":"m","reasoning_effort":"high"}}"#.utf8)
        #expect(try JSONDecoder().decode(AppSettings.self, from: legacy).meetingReminders.enabled == false)
        let encoded = String(decoding: try JSONEncoder().encode(AppSettings()), as: UTF8.self)
        #expect(encoded.contains(#""meeting_reminders":{"enabled":false}"#))

        let paths = try temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.dataDirectory.deletingLastPathComponent()) }
        let settings = AppSettings(meetingReminders: MeetingReminderSettings(enabled: true))
        try await Store(paths: paths).saveSettings(settings)
        #expect(try await Store(paths: paths).settings() == settings)
    }
}
