import StillnoteCore
import SwiftUI

/// The summary agent, its prompt, and meeting tag suggestions.
struct SummarizeSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var provider = SummaryProvider.codex
    @State private var summaryModel = ""
    @State private var effort = ReasoningEffort.high
    @State private var agentPrompt = Summarizer.defaultAgentPrompt
    @State private var concurrency = AgentJobLimiter.defaultLimit
    @State private var loaded = false

    private var availability: AgentAvailability? {
        model.agents.first { $0.provider == provider }
    }

    var body: some View {
        SettingsSection("Agent") {
            SettingsCard {
                SettingsRow("Provider") { providerPicker }
                if availability?.installed == true {
                    SettingsStatusRow(ok: true, title: "\(provider.label) installed",
                                      caption: "Uses your CLI sign-in. Stillnote stores no API key.") { checkAgain }
                } else {
                    SettingsStatusRow(ok: false, title: "Set up \(provider.label)",
                                      caption: "Install the \(provider.command) CLI, sign in, then check again.") { checkAgain }
                }
                SettingsRow("Model") {
                    SettingsTextField(label: "Model", prompt: provider.defaultModel, text: $summaryModel)
                }
                SettingsRow("Thinking effort") {
                    Picker("Thinking effort", selection: $effort) {
                        ForEach(provider.reasoningEfforts, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                SettingsRow(
                    "Jobs at once",
                    caption: "How many summaries and Name Meeting requests run at the same time. They don’t wait for transcription."
                ) {
                    SettingsStepper(label: "Jobs at once", value: $concurrency, step: 1,
                                    range: AgentJobLimiter.limits, format: { "\($0)" })
                }
            }
        }

        SettingsSection("Agent prompt") {
            Text(promptState)
                .font(SettingsMetrics.captionFont)
                .foregroundStyle(DS.text2)
        } content: {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $agentPrompt)
                        .font(SettingsMetrics.mono)
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 8)
                        .frame(height: 196)
                        .background(DS.well, in: .rect(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(DS.buttonBorder, lineWidth: 0.5)
                                .allowsHitTesting(false)
                        }
                        .accessibilityLabel("Agent prompt")
                    HStack(alignment: .center, spacing: 12) {
                        SettingsCaption("Keep the required JSON fields: overview, key_points, decisions, and action_items. A blank prompt uses the default.")
                        Button("Reset to Default") { agentPrompt = Summarizer.defaultAgentPrompt }
                            .buttonStyle(.settings)
                            .disabled(agentPrompt == Summarizer.defaultAgentPrompt)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }

        SettingsSection("Meeting tags") {
            MeetingTagsCard()
        }

        SettingsCaption("Summaries and Name Meeting send meeting text to the provider and model chosen here, without asking again.")
            .onAppear(perform: load)
            .onChange(of: summaryModel) { save() }
            .onChange(of: effort) { save() }
            .onChange(of: agentPrompt) { save() }
            .onChange(of: concurrency) { save() }
    }

    private var providerPicker: some View {
        HStack(spacing: 2) {
            ForEach(SummaryProvider.allCases, id: \.self) { item in
                let selected = item == provider
                Button { choose(item) } label: {
                    Text(item.label)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? DS.text : DS.text2)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(selected ? DS.segmentSelected : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                        .modifier(SegmentShadow(active: selected))
                        .contentShape(.rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(DS.segment, in: .rect(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider")
    }

    private var checkAgain: some View {
        Button("Check Again") { Task { await model.refreshEnvironment() } }
            .buttonStyle(SettingsLinkButtonStyle(size: 12.5))
    }

    private var promptState: String {
        if agentPrompt == Summarizer.defaultAgentPrompt { return "Default" }
        if agentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Blank · uses the default" }
        return "Edited"
    }

    private func choose(_ newValue: SummaryProvider) {
        guard newValue != provider else { return }
        provider = newValue
        summaryModel = newValue.defaultModel
        effort = effort.supported(by: newValue)
        save()
    }

    private func load() {
        provider = model.settings.summary.provider
        summaryModel = model.settings.summary.model
        effort = model.settings.summary.resolvedReasoningEffort
        agentPrompt = model.settings.summary.agentPrompt
        concurrency = model.settings.summary.concurrency
        loaded = true
    }

    private func save() {
        guard loaded else { return }
        let resolved = summaryModel.trimmingCharacters(in: .whitespaces).isEmpty
            ? provider.defaultModel : summaryModel
        let summary = SummarySettings(
            provider: provider, model: resolved, reasoningEffort: effort, agentPrompt: agentPrompt,
            concurrency: concurrency
        )
        model.changeSettings { $0.summary = summary }
    }
}

/// The selected segment's lift in light mode; dark mode uses the fill alone.
private struct SegmentShadow: ViewModifier {
    let active: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.shadow(color: active && scheme == .light ? .black.opacity(0.14) : .clear, radius: 1.5, y: 1)
    }
}

/// Suggested meeting tags, through OpenAI's Decisions API. The key goes to the Keychain, never
/// to the settings record.
private struct MeetingTagsCard: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var tagModel = TaggingSettings.defaultModel
    @State private var loaded = false

    var body: some View {
        SettingsCard {
            if let source = model.openAIKeySource {
                SettingsStatusRow(ok: true, title: source.label) { EmptyView() }
            } else {
                SettingsStatusRow(ok: false, title: "No OpenAI API key") { EmptyView() }
            }
            SettingsRow(
                "OpenAI API key",
                caption: "Saved in your Keychain. Without one, Stillnote uses \(OpenAICredentials.variable) from your shell."
            ) {
                HStack(spacing: 8) {
                    SettingsTextField(label: "OpenAI API key", prompt: "sk-…", text: $key, width: 180, secure: true)
                    Button("Save") {
                        let entered = key
                        key = ""
                        Task { await model.saveOpenAIKey(entered) }
                    }
                    .buttonStyle(.settings)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if model.openAIKeySource == .keychain {
                        Button("Remove") { Task { await model.removeOpenAIKey() } }
                            .buttonStyle(.settings)
                    }
                }
            }
            SettingsRow("Model", caption: "Tag decisions use \(TaggingSettings.defaultModel).") {
                SettingsTextField(label: "Tag model", prompt: TaggingSettings.defaultModel, text: $tagModel)
            }
            SettingsRow(
                "Suggest tags after each summary",
                caption: "Suggest Tags and Auto-Tag Meetings send the meeting’s title and summary, or the opening of its "
                    + "transcript, with your tag names to OpenAI. Stillnote only adds tags you created; it never removes one."
            ) {
                SettingsSwitch("Suggest tags after each summary", isOn: model.setting(\.tagging.autoTagAfterSummary))
            }
        }
        .onAppear {
            tagModel = model.settings.tagging.model
            loaded = true
            Task { await model.refreshOpenAIKey() }
        }
        .onChange(of: tagModel) {
            guard loaded else { return }
            let resolved = tagModel.trimmingCharacters(in: .whitespaces).isEmpty ? TaggingSettings.defaultModel : tagModel
            model.changeSettings { $0.tagging.model = resolved }
        }
    }
}
