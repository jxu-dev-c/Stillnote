import AppKit
import StillnoteCore
import SwiftUI

/// The menu bar icon: a waveform at rest, and a record symbol with the elapsed time while a
/// recording is open, so capture is never running unnoticed.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content
            // The meeting reminder lives outside any scene and borrows this one to open the window.
            .onAppear {
                model.meetingReminder.openMainWindow = { openWindow(id: StillnoteApp.mainWindowID) }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.isRecording, let session = model.recorder.session {
            HStack(spacing: 4) {
                Image(systemName: session.status == .paused ? "pause.circle.fill" : "record.circle.fill")
                Text(Formatting.duration(session.elapsed)).monospacedDigit()
            }
            .accessibilityLabel("Stillnote, \(session.status == .paused ? "recording paused" : "recording")")
        } else {
            Image(systemName: "waveform")
                .accessibilityLabel("Stillnote")
        }
    }
}

/// Start or stop a recording, and reach the app or its settings, without the main window.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
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
        Button(model.speech.ready ? "Stop & Transcribe" : "Stop & Save") { Task { await stop() } }
            .disabled(session.status == .starting || session.status == .stopping)
    }

    private func status(_ session: RecordingSessionState) -> String {
        switch session.status {
        case .starting: return "Waiting for permissions"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Saving"
        case .stopped: return "Ready to save"
        }
    }

    private func start() async {
        await model.refreshEnvironment()
        // The main window is where a failure, or a macOS permission problem, is explained.
        if await !model.startQuickRecording() { showMainWindow() }
    }

    private func stop() async {
        if await model.stopRecording() == nil { showMainWindow() }
    }

    private func showMainWindow() {
        NSApp.activate()
        openWindow(id: StillnoteApp.mainWindowID)
    }
}
