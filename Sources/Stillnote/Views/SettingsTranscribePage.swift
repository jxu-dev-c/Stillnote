import StillnoteCore
import SwiftUI

/// The speech model, transcription defaults, and hot words.
struct TranscribeSettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsSection("Speech model") {
            SpeechModelCard()
        }

        SettingsSection("Defaults") {
            SettingsCard {
                SettingsRow("Mode", caption: model.settings.transcription.mode.detail) {
                    menu("Mode", selection: model.setting(\.transcription.mode)) {
                        ForEach(TranscriptionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                SettingsRow("Language") {
                    menu("Language", selection: model.setting(\.transcription.language)) {
                        ForEach(transcriptionLanguages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                }
                SettingsRow("Speakers") {
                    menu("Speakers", selection: model.setting(\.transcription.speakerCount)) {
                        Text("Detect automatically").tag(Int?.none)
                        ForEach(1...10, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                    }
                }
            }
        }

        SettingsSection("Hot words") {
            HotWordsCard()
        }
    }

    private func menu<Value: Hashable, Options: View>(
        _ label: String, selection: Binding<Value>, @ViewBuilder options: () -> Options
    ) -> some View {
        Picker(label, selection: selection, content: options)
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
    }
}

private struct SpeechModelCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let speech = model.speech
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    SettingsIconTile(icon: .waveform)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(speech.modelName).font(.system(size: 15, weight: .semibold))
                            badge
                        }
                        Text("\(speech.downloadMegabytes.formatted()) MB · runs locally")
                            .font(SettingsMetrics.captionFont)
                            .foregroundStyle(DS.text2)
                    }
                    Spacer(minLength: 0)
                }
                .help(speech.engine)
                SettingsCaption(speech.detail)
                if let error = speech.error {
                    SettingsNotice(text: error)
                }
                if speech.installing {
                    ProgressView(value: speech.progress, total: 100)
                        .tint(DS.accent)
                }
                if !speech.runtimeReady, speech.detail != SpeechWorkerLocator.repairMessage {
                    SettingsCaption(SpeechWorkerLocator.repairMessage)
                }
            }
            .padding(14)

            HStack(spacing: 8) {
                if let url = speech.infoURL {
                    Link(destination: url) { Text("Model details") }
                        .buttonStyle(.settingsLink)
                }
                Spacer(minLength: 0)
                Button(installTitle) { Task { await model.installModel() } }
                    .buttonStyle(.settings)
                    .disabled(speech.installing)
                Button("Check Again") { Task { await model.refreshEnvironment() } }
                    .buttonStyle(.settings)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var badge: some View {
        let speech = model.speech
        if speech.installing {
            SettingsBadge(text: "Downloading", tone: .away)
        } else if !speech.modelInstalled {
            SettingsBadge(text: "Not downloaded", tone: .away)
        } else if !speech.runtimeReady {
            SettingsBadge(text: "Needs repair", tone: .away)
        } else {
            SettingsBadge(text: "Ready", tone: .ok)
        }
    }

    private var installTitle: String {
        if model.speech.installing { return "Downloading…" }
        return model.speech.modelInstalled ? "Check / Repair" : "Download Model"
    }
}

/// Hot words as removable chips. Return adds the typed word, and Delete in an empty field
/// removes the last one. Every change saves at once.
private struct HotWordsCard: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var words: [String] { model.settings.transcription.hotWords }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                SettingsCaption("Names, acronyms, and specialized terms help guide recognition; they are not guaranteed replacements. Keep phrases such as New York together as one entry.")
                FlowLayout(spacing: 6, lineSpacing: 6, fillsLastLine: true) {
                    ForEach(words, id: \.self) { word in chip(word) }
                    TextField("Add a hot word", text: $draft, prompt: Text("Add a word, press Return"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($fieldFocused)
                        .focusEffectDisabled()
                        .frame(minWidth: 160)
                        .frame(height: 26)
                        .padding(.horizontal, 6)
                        .onSubmit(add)
                        .modifier(DeleteInEmptyField(active: fieldFocused && draft.isEmpty && !words.isEmpty) {
                            model.changeSettings { settings in
                                if !settings.transcription.hotWords.isEmpty { settings.transcription.hotWords.removeLast() }
                            }
                        })
                        .accessibilityHint("Press Return to add. Keep phrases such as New York on one entry.")
                }
                .padding(6)
                .background(DS.well, in: shape)
                .overlay {
                    shape.strokeBorder(fieldFocused ? DS.accent.opacity(0.6) : DS.buttonBorder,
                                       lineWidth: fieldFocused ? 1.5 : 0.5)
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
                .onTapGesture { fieldFocused = true }
                HStack(alignment: .firstTextBaseline) {
                    SettingsCaption("Saved for all your transcriptions, including retranscriptions. Clear the list to stop using hot words.")
                    Button("Clear") { save([]) }
                        .buttonStyle(SettingsLinkButtonStyle(size: 12))
                        .disabled(words.isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func chip(_ word: String) -> some View {
        HStack(spacing: 2) {
            Text(word).font(.system(size: 13)).foregroundStyle(DS.text)
            Button { save(words.filter { $0 != word }) } label: {
                Icon(.close, size: 10, lineWidth: 2)
                    .foregroundStyle(DS.text2)
                    .frame(width: 22, height: 22)
                    .hoverFill(.circle, color: DS.settingsHover)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(word)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 26)
        .background(DS.chip, in: .capsule)
    }

    private func add() {
        let entry = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        fieldFocused = true
        guard !entry.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) else { return }
        save(words + [entry])
    }

    private func save(_ updated: [String]) {
        let normalized = TranscriptionSettings.normalizeHotWords(updated)
        model.changeSettings { $0.transcription.hotWords = normalized }
    }
}

/// Runs `action` when Delete is pressed while `active`. A text field's editor consumes Delete
/// before SwiftUI's key-press handlers see it, so a local monitor watches for it instead, and only
/// while the field is focused and empty, when Delete would otherwise do nothing.
private struct DeleteInEmptyField: ViewModifier {
    let active: Bool
    let action: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { _, active in
                remove()
                guard active else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                    guard event.keyCode == 51 /* kVK_Delete */, modifiers.isEmpty else { return event }
                    action()
                    return nil
                }
            }
            .onDisappear(perform: remove)
    }

    private func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
