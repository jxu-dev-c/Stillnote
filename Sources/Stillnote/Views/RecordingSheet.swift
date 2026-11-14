import StillnoteCore
import SwiftUI

struct RecordingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String?

    @State private var microphoneID = ""
    @State private var displayID: UInt32?
    @State private var systemAudio = false
    @State private var screenVideo = false
    @State private var language = "auto"
    @State private var speakerCount: Int?
    @State private var starting = false
    @State private var error: String?
    @State private var initialized = false

    /// Recording options. Once a recording starts, the window shows it and this sheet closes.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            setup
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(starting)
        .onAppear(perform: prepare)
    }

    // MARK: - Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Recording").font(.title2.weight(.semibold))

            if !model.capabilities.available, let reason = model.capabilities.reason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
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
            .frame(height: screenVideo ? 245 : 195)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(model.speech.ready
                ? "The meeting is titled after its summary. You can rename it any time."
                : "Recordings are saved now and can be transcribed once the speech model is installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Refresh Devices") { Task { await model.refreshEnvironment() } }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(starting)
                Button(starting ? "Starting…" : "Start Recording") { Task { await start() } }
                    .primaryActionStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(starting || !model.capabilities.available)
            }
        }
    }

    // MARK: - Actions

    private func prepare() {
        if !initialized {
            language = model.settings.transcription.language
            speakerCount = model.settings.transcription.speakerCount
            initialized = true
        }
        Task { await model.refreshEnvironment() }
        displayID = displayID ?? model.capabilities.defaultDisplayID
    }

    private func start() async {
        error = nil
        starting = true
        defer { starting = false }
        do {
            let options = CaptureOptions(
                title: CaptureOptions.defaultTitle(), language: try Validation.language(language),
                speakerCount: try Validation.speakerCount(speakerCount), microphoneID: microphoneID,
                displayID: displayID, systemAudio: systemAudio, screenVideo: screenVideo,
                automaticTitle: true
            )
            try await model.recorder.start(options: options)
            selection = RecordingSelection.id
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
