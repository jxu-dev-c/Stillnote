import StillnoteCore
import SwiftUI

struct RecordingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String?

    @State private var title = ""
    @State private var microphoneID = ""
    @State private var displayID: UInt32?
    @State private var systemAudio = true
    @State private var screenVideo = false
    @State private var language = "auto"
    @State private var speakerCount: Int?
    @State private var starting = false
    @State private var error: String?
    @State private var confirmingDiscard = false
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let session = model.recorder.session {
                active(session)
            } else {
                setup
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: prepare)
        .confirmationDialog(
            "Discard this recording?", isPresented: $confirmingDiscard, titleVisibility: .visible
        ) {
            Button("Discard Recording", role: .destructive) {
                Task {
                    await model.recorder.discard()
                    dismiss()
                }
            }
        } message: {
            Text("Stops recording and deletes the unsaved audio and video.")
        }
    }

    // MARK: - Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New recording").font(.headline)

            if !model.capabilities.available, let reason = model.capabilities.reason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                TextField("Title", text: $title)
                Picker("Microphone", selection: $microphoneID) {
                    Text("System default microphone").tag("")
                    ForEach(model.capabilities.microphones) { Text($0.name).tag($0.id) }
                }
                Toggle("Include system audio", isOn: $systemAudio)
                Toggle("Record screen video", isOn: $screenVideo)
                if screenVideo {
                    Picker("Display", selection: $displayID) {
                        ForEach(model.capabilities.displays) { Text($0.name).tag(UInt32?.some($0.id)) }
                    }
                }
                TranscriptionOptionFields(language: $language, speakerCount: $speakerCount)
            }
            .formStyle(.grouped)
            .frame(height: 230)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.speech.ready {
                Text("Recordings are saved now and can be transcribed once the speech model is installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Refresh Devices") { Task { await model.refreshEnvironment() } }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(starting ? "Starting…" : "Start Recording") { Task { await start() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(starting || !model.capabilities.available)
            }
        }
    }

    // MARK: - Active session

    private func active(_ session: RecordingSessionState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(statusText(session), systemImage: statusSymbol(session))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(session.status == .recording ? .red : .secondary)

            Text(Formatting.duration(session.elapsed))
                .font(.system(size: 44, weight: .light))
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .center)

            meter("Microphone", level: model.recorder.microphoneLevel, paused: session.status == .paused)
            if session.options.systemAudio {
                meter("System audio", level: model.recorder.systemLevel, paused: session.status == .paused)
            }

            LabeledContent("Meeting", value: session.options.title)
            if session.options.screenVideo {
                Label("Screen video enabled", systemImage: "display").font(.caption).foregroundStyle(.secondary)
            }

            if session.status == .starting {
                Text("Allow Microphone and Screen & System Audio Recording in the macOS prompts. "
                    + "If access was denied, enable Stillnote in System Settings → Privacy & Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Discard", role: .destructive) { confirmingDiscard = true }
                Spacer()
                if session.status == .recording {
                    Button("Pause") { model.recorder.pause() }
                } else if session.status == .paused {
                    Button("Resume") { model.recorder.resume() }
                }
                Button(finishTitle) { Task { await finish() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || session.status == .stopping)
            }
        }
    }

    private func meter(_ label: String, level: CaptureLevel?, paused: Bool) -> some View {
        // −60 dBFS to 0 dBFS, the range where speech is actually legible on a meter.
        let rms = level?.rms ?? 0
        let decibels = 20 * log10(max(rms, 0.001))
        let value = max(0, min(1, (decibels + 60) / 60))
        return VStack(alignment: .leading, spacing: 2) {
            Gauge(value: value) {
                Text(label)
            } currentValueLabel: {
                Text(rms > 0.001 ? String(format: "%.0f dB", decibels) : "−∞ dB").monospacedDigit()
            }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(level?.peak ?? 0 >= 0.98 ? .orange : .accentColor)
            Text(meterState(level: level, paused: paused))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func meterState(level: CaptureLevel?, paused: Bool) -> String {
        if paused { return "Paused" }
        guard let level else { return "Quiet" }
        if level.peak >= 0.98 { return "Input clipping" }
        return level.rms > 0.002 ? "Receiving audio" : "Quiet"
    }

    private func statusText(_ session: RecordingSessionState) -> String {
        switch session.status {
        case .starting: return "Waiting for macOS permissions"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .stopping: return "Finishing recording"
        case .stopped: return "Ready to save"
        }
    }

    private func statusSymbol(_ session: RecordingSessionState) -> String {
        switch session.status {
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle"
        case .stopping: return "hourglass"
        case .stopped: return "checkmark.circle"
        case .starting: return "lock.shield"
        }
    }

    private var finishTitle: String {
        if saving { return "Saving…" }
        return model.speech.ready ? "Finish & Transcribe" : "Save Recording"
    }

    // MARK: - Actions

    private func prepare() {
        Task { await model.refreshEnvironment() }
        if title.isEmpty {
            title = "Meeting · " + Date().formatted(.dateTime.month(.abbreviated).day())
        }
        displayID = displayID ?? model.capabilities.defaultDisplayID
    }

    private func start() async {
        error = nil
        starting = true
        defer { starting = false }
        do {
            let options = CaptureOptions(
                title: try Validation.title(title), language: try Validation.language(language),
                speakerCount: try Validation.speakerCount(speakerCount), microphoneID: microphoneID,
                displayID: displayID, systemAudio: systemAudio, screenVideo: screenVideo
            )
            try await model.recorder.start(options: options)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func finish() async {
        saving = true
        defer { saving = false }
        guard let meeting = await model.finishRecording() else { return }
        selection = meeting.id
        dismiss()
        if model.speech.ready {
            await model.transcribe(meeting.id)
        }
    }
}
