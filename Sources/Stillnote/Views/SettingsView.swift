import StillnoteCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            TranscriptionSettingsView()
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .tag("transcription")
            SpeakerSettingsView()
                .tabItem { Label("Speakers", systemImage: "person.2") }
                .tag("speakers")
            SummarySettingsView()
                .tabItem { Label("Summaries", systemImage: "sparkles") }
                .tag("summaries")
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "terminal") }
                .tag("advanced")
        }
        .frame(height: 420)
    }
}

struct TranscriptionSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var language = "auto"
    @State private var speakerCount: Int?
    @State private var mode = TranscriptionMode.quality
    @State private var hotWordsText = ""
    @State private var savingHotWords = false
    @State private var trimRecording = true
    @State private var suppressNonSpeech = true
    @State private var sensitivity = CleanupSensitivity.balanced

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Mode", selection: $mode) {
                    ForEach(TranscriptionMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                TranscriptionOptionFields(language: $language, speakerCount: $speakerCount)
            }

            Section("Recording cleanup") {
                Toggle("Trim silence from saved recordings", isOn: $trimRecording)
                Text("Removes leading and trailing silence when a recording is saved, for the times a recording kept running after the meeting ended. The recording file is rewritten, and only cuts longer than a minute are applied.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Silence background noise between speech", isOn: $suppressNonSpeech)
                Text("Mutes typing, fans, and static wherever nobody is speaking, in the copy sent to transcription only. Speech itself is never filtered, so recognition accuracy is unaffected and playback keeps the original audio.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Sensitivity", selection: $sensitivity) {
                    ForEach(CleanupSensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(!trimRecording && !suppressNonSpeech)
                Text(sensitivity.detail).font(.caption).foregroundStyle(.secondary)
                if !model.speech.cleanupAvailable {
                    Text("Download the speech models to enable cleanup. Until then recordings are saved and transcribed in full.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Hot words") {
                Text("Enter one word or phrase per line. Names, acronyms, and specialized terms help guide recognition; they are not guaranteed replacements.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $hotWordsText)
                    .frame(height: 90)
                    .overlay(alignment: .topLeading) {
                        if hotWordsText.isEmpty {
                            Text("One entry per line. Keep phrases with spaces together.\nOpenMOSS\nAPI\nNew York")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityLabel("Hot words, one word or phrase per line")
                    .accessibilityHint("Press Return between entries. Keep phrases such as New York on one line.")
                    .disabled(savingHotWords)
                HStack {
                    Button("Clear") { hotWordsText = "" }
                        .disabled(hotWordsText.isEmpty || savingHotWords)
                    Button("Save Hot Words") {
                        savingHotWords = true
                        var updated = model.settings
                        updated.transcription.hotWords = normalizedHotWords
                        Task {
                            await model.saveSettings(updated)
                            if model.settings.transcription.hotWords == updated.transcription.hotWords {
                                hotWordsText = model.settings.transcription.hotWords.joined(separator: "\n")
                            }
                            savingHotWords = false
                        }
                    }
                    .disabled(savingHotWords || normalizedHotWords == model.settings.transcription.hotWords)
                }
                Text("Saved for all your transcriptions, including retranscriptions. Clear and save to stop using hot words.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Speech model") {
                LabeledContent(model.speech.modelName) {
                    Text("\(model.speech.downloadMegabytes) MB · runs locally").foregroundStyle(.secondary)
                }
                if let url = model.speech.infoURL {
                    Link("Model details", destination: url)
                }
                Text(model.speech.detail).font(.callout).foregroundStyle(.secondary)
                if let error = model.speech.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if model.speech.installing {
                    ProgressView(value: model.speech.progress, total: 100)
                }
                HStack {
                    Button(buttonTitle) { Task { await model.installModel() } }
                        .disabled(model.speech.installing)
                    Button("Check Again") { Task { await model.refreshEnvironment() } }
                }
                LabeledContent("Engine", value: model.speech.engine)
                if !model.speech.runtimeReady {
                    Text(SpeechWorkerLocator.repairMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            mode = model.settings.transcription.mode
            language = model.settings.transcription.language
            speakerCount = model.settings.transcription.speakerCount
            hotWordsText = model.settings.transcription.hotWords.joined(separator: "\n")
            trimRecording = model.settings.cleanup.trimRecording
            suppressNonSpeech = model.settings.cleanup.suppressNonSpeech
            sensitivity = model.settings.cleanup.sensitivity
        }
        .onChange(of: mode) { save() }
        .onChange(of: language) { save() }
        .onChange(of: speakerCount) { save() }
        .onChange(of: trimRecording) { save() }
        .onChange(of: suppressNonSpeech) { save() }
        .onChange(of: sensitivity) { save() }
    }

    private var normalizedHotWords: [String] {
        TranscriptionSettings.normalizeHotWords(hotWordsText.components(separatedBy: .newlines))
    }

    private var buttonTitle: String {
        if model.speech.installing { return "Downloading…" }
        return model.speech.modelInstalled ? "Check / Repair" : "Download Model"
    }

    private func save() {
        var updated = model.settings
        guard updated.transcription.mode != mode || updated.transcription.language != language
            || updated.transcription.speakerCount != speakerCount
            || updated.cleanup.trimRecording != trimRecording
            || updated.cleanup.suppressNonSpeech != suppressNonSpeech
            || updated.cleanup.sensitivity != sensitivity
        else { return }
        updated.transcription.mode = mode
        updated.transcription.language = language
        updated.transcription.speakerCount = speakerCount
        updated.cleanup.trimRecording = trimRecording
        updated.cleanup.suppressNonSpeech = suppressNonSpeech
        updated.cleanup.sensitivity = sensitivity
        Task { await model.saveSettings(updated) }
    }
}

struct SummarySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var provider = SummaryProvider.codex
    @State private var summaryModel = ""
    @State private var effort = ReasoningEffort.high
    @State private var agentPrompt = Summarizer.defaultAgentPrompt
    @State private var inheritShellEnvironment = true
    @State private var shellPath = ""
    @State private var bypassPermissions = true

    private var availability: AgentAvailability? {
        model.agents.first { $0.provider == provider }
    }

    var body: some View {
        Form {
            Section("Agent") {
                Picker("Provider", selection: Binding(
                    get: { provider },
                    set: { newValue in
                        guard newValue != provider else { return }
                        provider = newValue
                        summaryModel = newValue.defaultModel
                        save()
                    }
                )) {
                    ForEach(SummaryProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                TextField("Model", text: $summaryModel, prompt: Text(provider.defaultModel))
                Picker("Thinking effort", selection: $effort) {
                    ForEach(ReasoningEffort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }

            Section("Permissions") {
                Toggle("YOLO / Skip permission checks", isOn: $bypassPermissions)
                Text("Uses Codex YOLO mode or Claude Code’s dangerously-skip-permissions mode. When enabled, the CLI can act without permission prompts; Codex also disables its sandbox.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("CLI environment") {
                Toggle("Inherit shell environment", isOn: $inheritShellEnvironment)
                Text("Loads exported API credentials, provider settings, and PATH from your shell when running either CLI. Works when Stillnote is opened from Finder.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Shell path", text: $shellPath, prompt: Text("Automatic — account login shell"))
                    .disabled(!inheritShellEnvironment)
                Text("Leave blank to use your account’s shell, or enter a full path such as /bin/zsh or /bin/bash. Startup files must export the variables your CLI needs. Turn inheritance off to use only the app’s environment.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Agent prompt") {
                TextEditor(text: $agentPrompt)
                    .font(.body.monospaced())
                    .frame(height: 180)
                    .accessibilityLabel("Agent prompt")
                Text("Keep the required JSON fields: overview, key_points, decisions, and action_items. A blank prompt uses the default.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset to Default") { agentPrompt = Summarizer.defaultAgentPrompt }
                    .disabled(agentPrompt == Summarizer.defaultAgentPrompt)
            }

            Section("Status") {
                if availability?.installed == true {
                    Label("\(provider.label) installed", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("Uses your CLI sign-in. Stillnote stores no API key.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Set up \(provider.label)", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Text("Install the \(provider.command) CLI, sign in, then check again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Check Again") { Task { await model.refreshEnvironment() } }
            }

            Section {
                Text("Summaries send transcript text to the model provider. You confirm each time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            provider = model.settings.summary.provider
            summaryModel = model.settings.summary.model
            effort = model.settings.summary.reasoningEffort
            agentPrompt = model.settings.summary.agentPrompt
            inheritShellEnvironment = model.settings.summary.inheritShellEnvironment
            shellPath = model.settings.summary.shellPath
            bypassPermissions = model.settings.summary.bypassPermissions
        }
        .onChange(of: summaryModel) { save() }
        .onChange(of: effort) { save() }
        .onChange(of: agentPrompt) { save() }
        .onChange(of: inheritShellEnvironment) { save() }
        .onChange(of: shellPath) { save() }
        .onChange(of: bypassPermissions) { save() }
    }

    private func save() {
        var updated = model.settings
        let resolved = summaryModel.trimmingCharacters(in: .whitespaces).isEmpty
            ? provider.defaultModel : summaryModel
        guard updated.summary.provider != provider || updated.summary.model != resolved
            || updated.summary.reasoningEffort != effort || updated.summary.agentPrompt != agentPrompt
            || updated.summary.inheritShellEnvironment != inheritShellEnvironment
            || updated.summary.shellPath != shellPath
            || updated.summary.bypassPermissions != bypassPermissions
        else { return }
        updated.summary = SummarySettings(
            provider: provider, model: resolved, reasoningEffort: effort, agentPrompt: agentPrompt,
            inheritShellEnvironment: inheritShellEnvironment, shellPath: shellPath, bypassPermissions: bypassPermissions
        )
        Task { await model.saveSettings(updated) }
    }
}

/// The command interface: a local socket the bundled `stillnote` CLI talks to.
struct AdvancedSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var enabled = true

    var body: some View {
        Form {
            Section("Command line") {
                Toggle("Allow the stillnote command to control this app", isOn: $enabled)
                Text("Stillnote listens on a socket inside your library folder so the bundled stillnote command, and any agent you point at it, can read and correct meetings and start or stop a recording. It is a file only your macOS account can open; nothing is sent anywhere and no network port is used.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Turn this off to refuse every command, including starting a recording. Summaries still need their own per-request consent.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Socket", value: model.paths.commandSocketURL.path)
                    .font(.caption)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { enabled = model.settings.cli.enabled }
        .onChange(of: enabled) { _, value in
            guard value != model.settings.cli.enabled else { return }
            var updated = model.settings
            updated.cli.enabled = value
            Task { await model.saveSettings(updated) }
        }
    }
}
