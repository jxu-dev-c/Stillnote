import AppKit
import StillnoteCore
import SwiftUI

/// The menu bar icon: a waveform at rest, and a record symbol with the elapsed time while a
/// recording is open, so capture is never running unnoticed. A warning symbol stands in for the
/// waveform while an error waits to be read, since menu bar actions never bring a window forward.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    @ViewBuilder
    var body: some View {
        if model.isRecording, let session = model.recorder.session {
            HStack(spacing: 4) {
                Image(systemName: session.status == .paused ? "pause.circle.fill" : "record.circle.fill")
                Text(Formatting.duration(session.elapsed)).monospacedDigit()
            }
            .accessibilityLabel("Stillnote, \(session.status == .paused ? "recording paused" : "recording")")
        } else if model.alertMessage != nil {
            Image(systemName: "exclamationmark.triangle")
                .accessibilityLabel("Stillnote, needs attention")
        } else {
            Image(systemName: "waveform")
                .accessibilityLabel("Stillnote")
        }
    }
}

/// Start or stop a recording, and reach the app or its settings, without the main window.
/// Only Open Stillnote and Settings… bring a window forward: recording actions leave the app
/// hidden, and a failure is shown here and in the icon until it is read in the main window.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let message = model.alertMessage {
            Text("⚠︎ \(message)")
            Text("Open Stillnote to review")
            Divider()
        }
        if !model.isReady {
            Text(model.startupError == nil ? "Opening your library…" : "Stillnote could not open its library")
        } else if let session = model.recorder.session {
            active(session)
        } else {
            Button("Start Recording") { Task { await start() } }
                .disabled(!model.capabilities.available)
            if !model.capabilities.available, let reason = model.capabilities.reason {
                Text(reason)
            }
        }

        Divider()

        Button("Open Stillnote") { showMainWindow() }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        .disabled(!model.isReady)

        Divider()

        Button("Quit Stillnote") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private func active(_ session: RecordingSessionState) -> some View {
        Text("\(status(session)) · \(Formatting.duration(session.elapsed))")
        switch session.status {
        case .recording:
            Button("Pause Recording") { model.recorder.pause() }
        case .paused:
            Button("Resume Recording") { model.recorder.resume() }
        default:
            EmptyView()
        }
        // A session recovered after a crash is `stopped`: saving it is still the way forward.
        if model.recorder.isSaving {
            Button("Saving…") {}.disabled(true)
        } else {
            let unavailable = session.status == .starting || session.status == .stopping
            Button("Stop Recording") { Task { await stop(summarize: false) } }
                .disabled(unavailable)
            // Without the speech model there is nothing to transcribe, as in the recording sheet.
            if model.speech.ready {
                Button("Stop, Transcribe & Summarize") { Task { await stop(summarize: true) } }
                    .disabled(unavailable)
            }
        }
    }

    private func status(_ session: RecordingSessionState) -> String {
        if model.recorder.isSaving { return "Saving" }
        switch session.status {
        case .starting: return "Waiting for permissions"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Saving"
        case .stopped: return "Ready to save"
        }
    }

    // A failure sets `alertMessage`, which this menu and its icon show without raising a window.
    private func start() async {
        await model.refreshEnvironment()
        await model.startQuickRecording()
    }

    private func stop(summarize: Bool) async {
        await model.stopRecording(summarize: summarize)
    }

    private func showMainWindow() {
        NSApp.activate()
        openWindow(id: StillnoteApp.mainWindowID)
    }
}
