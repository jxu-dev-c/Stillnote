import AppKit
import Observation
import StillnoteCore

/// Offers to record when a meeting app or browser starts using the microphone. The monitor runs
/// only while the opt-in setting is on; when it is off nothing observes microphone use at all.
@MainActor
final class MeetingReminder {
    /// Brings the main window forward, where a failed start is explained. Set by the menu bar
    /// label, which lives in a scene and so can open windows.
    var openMainWindow: (() -> Void)?

    private weak var model: AppModel?
    private let monitor = MicrophoneActivityMonitor()
    private var policy = MeetingReminderPolicy()
    private var active: Set<MeetingApp> = []
    private var listening: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    /// Identifies the current recording observation, so one left from before a stop and restart
    /// ends instead of running beside the new one.
    private var observation = 0
    private lazy var panel = MeetingReminderPanel()

    /// Starts or stops observing to match the saved setting, then re-evaluates the reminder.
    func sync(model: AppModel) {
        self.model = model
        if model.isReady, model.settings.meetingReminders.enabled {
            if listening == nil { start() }
            evaluate()
        } else {
            stop()
        }
    }

    private func start() {
        let stream = monitor.start()
        listening = Task { [weak self] in
            for await apps in stream {
                guard let self else { return }
                self.active = apps
                self.evaluate()
            }
        }
        observeRecording()
    }

    private func stop() {
        guard listening != nil else { return }
        monitor.stop()
        listening?.cancel()
        listening = nil
        observation += 1
        deadline?.cancel()
        deadline = nil
        active = []
        policy = MeetingReminderPolicy()
        panel.hide()
    }

    /// A recording started from anywhere — the window, the menu bar, or the command line —
    /// withdraws the reminder.
    private func observeRecording() {
        guard listening != nil, let model else { return }
        let current = observation
        withObservationTracking {
            _ = model.isRecording
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.observation == current else { return }
                self.evaluate()
                self.observeRecording()
            }
        }
    }

    private func evaluate() {
        guard listening != nil, let model else { return }
        let context = MeetingReminderPolicy.Context(
            enabled: model.settings.meetingReminders.enabled, isRecording: model.isRecording
        )
        switch policy.update(active: active, now: Date(), context: context) {
        case .show(let app):
            panel.show(
                app: app,
                onStart: { [weak self] in self?.startRecording() },
                onClose: { [weak self] in self?.close() }
            )
        case .hide:
            panel.hide()
        case nil:
            break
        }
        scheduleDeadline()
    }

    /// The policy has timed rules — an app settling on the microphone, a reminder expiring — so
    /// wake once at the next of those, rather than ticking.
    private func scheduleDeadline() {
        deadline?.cancel()
        deadline = nil
        guard let next = policy.nextDeadline else { return }
        let delay = max(0, next.timeIntervalSinceNow) + 0.05
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    /// Closing only hides this reminder; the call it was about will not prompt again.
    private func close() {
        policy.dismiss()
        panel.hide()
        scheduleDeadline()
    }

    private func startRecording() {
        close()
        guard let model else { return }
        Task {
            await model.refreshEnvironment()
            // The main window is where a failure, or a macOS permission problem, is explained.
            if await !model.startQuickRecording() { showMainWindow() }
        }
    }

    private func showMainWindow() {
        NSApp.activate()
        openMainWindow?()
    }
}
