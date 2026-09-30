import Foundation

/// Decides when to offer to record, from which meeting apps currently hold the microphone. It is
/// a value with no clock or CoreAudio of its own, so the timing rules are testable.
///
/// - An app must hold the microphone for `settleDelay` first, so a meeting app probing the device
///   at launch does not prompt.
/// - Each microphone session prompts at most once. It counts as a new session only after the app
///   has left the microphone for `rearmDelay`, so muting and unmuting does not prompt again.
/// - A reminder is withdrawn when its app releases the microphone, when a recording starts, when
///   reminders are turned off, and after `displayDuration` without an answer.
public struct MeetingReminderPolicy: Sendable {
    public struct Context: Sendable {
        public var enabled: Bool
        public var isRecording: Bool

        public init(enabled: Bool, isRecording: Bool) {
            self.enabled = enabled
            self.isRecording = isRecording
        }
    }

    public enum Action: Equatable, Sendable {
        case show(MeetingApp)
        case hide
    }

    public static let settleDelay: TimeInterval = 2
    public static let rearmDelay: TimeInterval = 60
    public static let displayDuration: TimeInterval = 60

    public private(set) var showing: MeetingApp?
    private var shownAt: Date?
    /// When each app currently holding the microphone started to.
    private var activeSince: [String: Date] = [:]
    private var activeApps: [String: MeetingApp] = [:]
    /// When each app that held the microphone released it.
    private var releasedAt: [String: Date] = [:]
    /// Apps whose current microphone session has been handled already.
    private var handled: Set<String> = []
    private var context = Context(enabled: false, isRecording: false)

    public init() {}

    public mutating func update(active: Set<MeetingApp>, now: Date, context: Context) -> Action? {
        self.context = context
        let ids = Set(active.map(\.id))
        for app in active where activeSince[app.id] == nil {
            if let released = releasedAt[app.id], now.timeIntervalSince(released) >= Self.rearmDelay {
                handled.remove(app.id)
            }
            releasedAt[app.id] = nil
            activeSince[app.id] = now
            activeApps[app.id] = app
        }
        for id in activeSince.keys where !ids.contains(id) {
            activeSince[id] = nil
            activeApps[id] = nil
            releasedAt[id] = now
        }
        // A meeting that was being recorded has had its reminder.
        if context.isRecording { handled.formUnion(ids) }

        if let app = showing {
            let expired = shownAt.map { now.timeIntervalSince($0) >= Self.displayDuration } ?? true
            if !context.enabled || context.isRecording || !ids.contains(app.id) || expired {
                dismiss()
                return .hide
            }
            return nil
        }
        guard context.enabled, !context.isRecording else { return nil }
        let ready = pending.filter { now.timeIntervalSince($0.since) >= Self.settleDelay }
        guard let next = ready.min(by: { $0.since < $1.since }), let app = activeApps[next.id] else { return nil }
        handled.insert(app.id)
        showing = app
        shownAt = now
        return .show(app)
    }

    /// The reminder was answered or dismissed; its microphone session will not prompt again.
    public mutating func dismiss() {
        showing = nil
        shownAt = nil
    }

    /// When `update` next needs calling even if no app starts or stops using the microphone: when
    /// a waiting app has settled, or the visible reminder expires. Nil when nothing is pending.
    public var nextDeadline: Date? {
        if let shownAt { return shownAt.addingTimeInterval(Self.displayDuration) }
        guard context.enabled, !context.isRecording else { return nil }
        return pending.map { $0.since.addingTimeInterval(Self.settleDelay) }.min()
    }

    private var pending: [(id: String, since: Date)] {
        activeSince
            .filter { !handled.contains($0.key) }
            .map { (id: $0.key, since: $0.value) }
    }
}
