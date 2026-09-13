import StillnoteCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            TranscriptionSettingsView()
                .tabItem { Label("Transcription", systemImage: "waveform") }
            SummarySettingsView()
                .tabItem { Label("Summaries", systemImage: "sparkles") }
        }
        .frame(height: 420)
    }
}

struct TranscriptionSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var language = "auto"
    @State private var speakerCount: Int?

    var body: some View {
        Form {
            Section("Defaults") {
                TranscriptionOptionFields(language: $language, speakerCount: $speakerCount)
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
                    Text("Run ./scripts/setup.sh once to install the MOSS inference runtime.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            language = model.settings.transcription.language
            speakerCount = model.settings.transcription.speakerCount
        }
        .onChange(of: language) { save() }
        .onChange(of: speakerCount) { save() }
    }

    private var buttonTitle: String {
        if model.speech.installing { return "Downloading…" }
        return model.speech.modelInstalled ? "Check / Repair" : "Download Model"
    }

    private func save() {
        var updated = model.settings
        guard updated.transcription.language != language || updated.transcription.speakerCount != speakerCount
        else { return }
        updated.transcription.language = language
        updated.transcription.speakerCount = speakerCount
        Task { await model.saveSettings(updated) }
    }
}

struct SummarySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var provider = SummaryProvider.codex
    @State private var summaryModel = ""
    @State private var effort = ReasoningEffort.high

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
        }
        .onChange(of: summaryModel) { save() }
        .onChange(of: effort) { save() }
    }

    private func save() {
        var updated = model.settings
        let resolved = summaryModel.trimmingCharacters(in: .whitespaces).isEmpty
            ? provider.defaultModel : summaryModel
        guard updated.summary.provider != provider || updated.summary.model != resolved
            || updated.summary.reasoningEffort != effort
        else { return }
        updated.summary = SummarySettings(provider: provider, model: resolved, reasoningEffort: effort)
        Task { await model.saveSettings(updated) }
    }
}
