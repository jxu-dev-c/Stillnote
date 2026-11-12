import StillnoteCore
import SwiftUI

/// The recording in progress, shown in the window with the same anatomy as a transcript:
/// a speaker-style status, the running time, and a dock with the live input along it.
struct RecordingPage: View {
    @Environment(AppModel.self) private var model
    @Environment(Feedback.self) private var feedback
    @Binding var selection: String?

    @State private var page: MeetingPage = .transcript
    @State private var query = ""
    @State private var levels = LevelHistory()
    @State private var finishing: FinishAction?
    @State private var confirmingDiscard = false

    private enum FinishAction { case stop, summarize }

    var body: some View {
        if let session = model.recorder.session {
            content(session)
        } else {
            Color.clear
        }
    }

    private func content(_ session: RecordingSessionState) -> some View {
        VStack(spacing: 0) {
            DetailToolbar(actionsEnabled: false, deleteEnabled: false, page: $page, query: $query, onSearch: { _ in }) {
                ToolbarIconButton(icon: .nameMeeting, label: "Name Meeting", enabled: false) {}
                ToolbarIconButton(icon: .autoTag, label: "Auto-Tag Speakers", enabled: false) {}
                ToolbarIconButton(icon: .transcribeAgain, label: "Transcribe Again", enabled: false) {}
                ToolbarIconButton(icon: .regenerate, label: "Regenerate Summary", enabled: false) {}
            } delete: {
                ToolbarIconButton(icon: .trash, label: "Delete Meeting", tint: DS.danger, enabled: false) {}
            }
            VStack(spacing: 0) {
                header(session)
                switch page {
                case .transcript: live(session)
                case .summary: summaryPlaceholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toastOverlay(feedback, top: 12)
        }
        .onChange(of: model.recorder.microphoneLevel) { _, level in
            levels.append(max(level?.rms ?? 0, model.recorder.systemLevel?.rms ?? 0),
                          paused: model.recorder.session?.status != .recording)
        }
        .confirmationDialog("Discard this recording?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Recording", role: .destructive) {
                Task {
                    await model.recorder.discard()
                    selection = nil
                }
            }
        } message: {
            Text("Stops recording and deletes the unsaved audio and video.")
        }
    }

    private func header(_ session: RecordingSessionState) -> some View {
        let started = session.startedAt.flatMap(Meeting.parseTimestamp) ?? .now
        return HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("New Meeting")
                    .font(.system(size: 30, weight: .bold))
                    .letterSpacing(-0.025, size: 30)
                    .foregroundStyle(DS.text)
                    .frame(height: 34.5)
                HStack(spacing: 10) {
                    switch session.status {
                    case .recording: StatusPill(text: "Recording", tone: .record)
                    case .paused: StatusPill(text: "Paused", tone: .warning)
                    case .starting: StatusPill(text: "Starting", tone: .accent)
                    case .stopping, .stopped: StatusPill(text: model.recorder.isSaving ? "Saving" : "Stopped", tone: .accent)
                    }
                    Text("Started \(MeetingText.time(started))")
                        .font(.system(size: 13.5))
                        .foregroundStyle(DS.text2)
                }
                .padding(.top, 6)
                .frame(minHeight: 22)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 14, leading: 28, bottom: 4, trailing: 28))
    }

    private var summaryPlaceholder: some View {
        Text("No summary yet. A summary is created after the meeting ends.")
            .font(.system(size: 20, weight: .medium))
            .letterSpacing(-0.015, size: 20)
            .foregroundStyle(DS.text2)
            .frame(maxWidth: 780, alignment: .leading)
            .padding(EdgeInsets(top: 20, leading: 28, bottom: 0, trailing: 28))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Live

    private func live(_ session: RecordingSessionState) -> some View {
        var save: StatusAction?
        if session.status == .stopped && !model.recorder.isSaving {
            save = StatusAction("Save Recording") { Task { await finish(.stop) } }
        }
        return ZStack(alignment: .bottom) {
            StatusPage(
                labelView: { label(session) },
                bigView: { if session.status != .starting { RecordingTimer() } },
                message: message(session),
                action: save
            )
            BottomFade()
            dock(session)
                .padding(.leading, 28)
                .padding(.trailing, 32)
                .padding(.bottom, 22)
        }
    }

    @ViewBuilder
    private func label(_ session: RecordingSessionState) -> some View {
        switch session.status {
        case .recording:
            StatusLabel(text: "Listening", dot: DS.record, pulsing: true, detail: sources(session))
        case .paused:
            StatusLabel(text: "Paused", dot: .orange, detail: sources(session))
        case .starting:
            StatusLabel(text: "Waiting for permission", dot: DS.accent, pulsing: true)
        case .stopping:
            StatusLabel(text: "Finishing recording", dot: DS.accent, pulsing: true)
        case .stopped:
            StatusLabel(text: model.recorder.isSaving ? "Saving" : "Stopped", dot: DS.text3, pulsing: model.recorder.isSaving)
        }
    }

    private func sources(_ session: RecordingSessionState) -> String {
        var sources = [session.options.systemAudio ? "System audio and your microphone" : "Your microphone"]
        if session.options.screenVideo { sources.append("screen") }
        return sources.joined(separator: " · ")
    }

    private func message(_ session: RecordingSessionState) -> String? {
        if let error = session.error { return error }
        switch session.status {
        case .starting:
            return "Allow Microphone and Screen & System Audio Recording in the macOS prompts."
        case .paused:
            return "Recording is paused. Resume when you’re ready."
        default:
            return nil
        }
    }

    private func dock(_ session: RecordingSessionState) -> some View {
        let locked = finishing != nil || model.recorder.isSaving || session.status == .starting || session.status == .stopping
        let paused = session.status == .paused
        return HStack(spacing: 22) {
            HStack(spacing: 4) {
                Button {
                    paused ? model.recorder.resume() : model.recorder.pause()
                } label: {
                    Icon(paused ? .play : .pause, size: 22, filled: true)
                        .foregroundStyle(DS.text)
                        .frame(width: 44, height: 44)
                        .hoverFill(Circle())
                }
                .buttonStyle(.plain)
                .disabled(locked || !(session.status == .recording || paused))
                .help(paused ? "Resume recording" : "Pause recording")
                .accessibilityLabel(paused ? "Resume recording" : "Pause recording")

                Button { Task { await finish(model.speech.ready ? .summarize : .stop) } } label: {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .frame(width: 48, height: 48)
                        .background(DS.record, in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(locked)
                .help(model.speech.ready
                      ? "Stop, then transcribe and summarize. Right-click for more."
                      : "Stop and save the recording. Right-click for more.")
                .accessibilityLabel("Stop recording")
                .contextMenu {
                    Button("Stop, Transcribe & Summarize") { Task { await finish(.summarize) } }
                        .disabled(!model.speech.ready || locked)
                    Button("Stop Recording") { Task { await finish(.stop) } }
                        .disabled(locked)
                    Divider()
                    Button("Discard Recording…", role: .destructive) { confirmingDiscard = true }
                        .disabled(locked)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 60)
            .designGlassCapsule(blur: true)
            .opacity(locked ? 0.6 : 1)

            LiveStrip(levels: levels.values)
            HStack(spacing: 7) {
                if session.status == .recording {
                    PulsingDot(color: DS.record, size: 7)
                } else {
                    Circle().fill(DS.text3).frame(width: 7, height: 7)
                }
                RecordingClock(style: .compact)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DS.text2)
            .fixedSize()
        }
        .frame(height: 60)
    }

    // MARK: Actions

    private func finish(_ action: FinishAction) async {
        finishing = action
        defer { finishing = nil }
        guard let meeting = await model.finishRecording() else { return }
        selection = meeting.id
        if action == .summarize {
            let processed = await model.processRecording(meeting)
            // A split replaces the recording; show its first part unless the user moved on.
            if selection == meeting.id, let first = processed.first, first.id != meeting.id {
                selection = first.id
            }
        }
    }
}

/// 64-point minutes and seconds with the hundredths dimmed.
private struct RecordingTimer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let seconds = model.recorder.liveElapsed(at: context.date)
            let whole = Int(seconds)
            let clock = whole >= 3600
                ? String(format: "%d:%02d:%02d", whole / 3600, whole % 3600 / 60, whole % 60)
                : String(format: "%02d:%02d", whole / 60, whole % 60)
            BigFigure(value: clock, suffix: String(format: ".%02d", Int((seconds - Double(whole)) * 100)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording time")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The last 150 input levels, newest last.
struct LevelHistory {
    static let count = 150
    private(set) var values: [Double] = Array(repeating: 0, count: count)

    mutating func append(_ rms: Double, paused: Bool) {
        // −60 dBFS to 0 dBFS, the range where speech is legible on a meter.
        let decibels = 20 * log10(max(rms, 0.001))
        let level = paused ? 0 : max(0, min(1, (decibels + 60) / 60))
        values.removeFirst()
        values.append(level)
    }
}

/// Input level bars filling in from the right, with the red recording head at the edge.
private struct LiveStrip: View {
    let levels: [Double]

    var body: some View {
        Canvas { context, size in
            let count = levels.count
            let usable = size.width - 8
            let gap = (usable - CGFloat(count) * 2) / CGFloat(count - 1)
            for (index, level) in levels.enumerated() {
                let height = max(2, min(26, 2 + 24 * level))
                let rect = CGRect(x: CGFloat(index) * (2 + gap), y: (size.height - height) / 2, width: 2, height: height)
                let opacity = index > count - 16 ? 1 : 0.6
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(DS.text.opacity(opacity)))
            }
        }
        .overlay(alignment: .trailing) {
            Capsule()
                .fill(DS.record)
                .frame(width: 3)
                .padding(.vertical, 4)
                .shadow(color: DS.record, radius: 4)
        }
        .frame(height: 44)
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .accessibilityHidden(true)
    }
}
