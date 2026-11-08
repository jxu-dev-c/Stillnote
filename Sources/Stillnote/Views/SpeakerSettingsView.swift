import StillnoteCore
import SwiftUI

/// Voice recognition on top, speaker profiles below as a searchable master/detail card.
struct SpeakerSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var draft: SpeakerProfile?
    @State private var isNew = false
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDelete = false
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var original: SpeakerProfile? {
        model.speakerProfiles.first { $0.id == selection }
    }
    private var dirty: Bool { draft != nil && (isNew || draft != original) }
    private var filteredProfiles: [SpeakerProfile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.speakerProfiles }
        return model.speakerProfiles.filter { profile in
            [profile.name, profile.email, profile.phone].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            VoiceRecognitionSection()
                .settingsCard()
            profileEditor
                .settingsCard()
        }
        .padding(20)
    }

    // MARK: - Profiles

    private var profileEditor: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 240)
                .background(.quaternary.opacity(0.35))
            detail
                .disabled(saving)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            selection = model.requestedSpeakerProfileID ?? model.speakerProfiles.first?.id
            draft = original
            model.requestedSpeakerProfileID = nil
        }
        .onChange(of: model.requestedSpeakerProfileID) {
            guard let requested = model.requestedSpeakerProfileID else { return }
            if dirty {
                error = "Save or revert your changes before switching profiles."
            } else {
                search = ""
                selection = requested
                draft = original
            }
            model.requestedSpeakerProfileID = nil
        }
        .onChange(of: selection) {
            if !isNew { draft = original; error = nil }
        }
        .alert("Delete speaker profile?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete() }
        } message: {
            Text("Delete \(original?.name ?? "this speaker") and their contact details? Meeting names and summaries will be kept.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding([.horizontal, .top], 10)
                .padding(.bottom, 2)
            List(selection: $selection) {
                if isNew, let draft {
                    profileRow(name: draft.name.isEmpty ? "New Speaker" : draft.name)
                        .tag(draft.id)
                }
                ForEach(filteredProfiles) { profile in
                    profileRow(name: profile.name)
                        .tag(profile.id)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .alternatingRowBackgrounds(.disabled)
            .disabled(saving || dirty)
            .accessibilityLabel("Speaker profiles")
            .overlay {
                if filteredProfiles.isEmpty && !isNew {
                    emptyList
                }
            }
            HStack(spacing: 2) {
                Button {
                    let profile = SpeakerProfile(name: "")
                    search = ""
                    isNew = true
                    selection = profile.id
                    draft = profile
                    error = nil
                } label: { Image(systemName: "plus").frame(width: 22, height: 20) }
                .help("Add speaker profile")
                .accessibilityLabel("Add speaker profile")
                .disabled(saving || dirty)
                Button {
                    confirmingDelete = true
                } label: { Image(systemName: "minus").frame(width: 22, height: 20) }
                .help("Delete speaker profile")
                .accessibilityLabel("Delete speaker profile")
                .disabled(saving || selection == nil || isNew || dirty)
                Spacer()
                Text(countLabel)
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.trailing, 6)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("Search speaker profiles")
            if !search.isEmpty {
                Button {
                    search = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(searchFocused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
    }

    private func profileRow(name: String) -> some View {
        HStack(spacing: 9) {
            SpeakerAvatar(name: name, color: .primary, size: 24)
                .accessibilityHidden(true)
            Text(name).lineLimit(1).truncationMode(.tail)
        }
        .help(name)
        .padding(.vertical, 1)
        .listRowSeparator(.hidden)
    }

    private var emptyList: some View {
        VStack(spacing: 6) {
            Image(systemName: search.isEmpty ? "person.2" : "magnifyingglass")
                .font(.title2).foregroundStyle(.tertiary)
            Text(search.isEmpty ? "No speakers yet" : "No matches")
                .font(.callout.weight(.medium))
            Text(search.isEmpty ? "Use + to add one." : "Try a name, email, or phone.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding()
        .allowsHitTesting(false)
    }

    private var countLabel: String {
        let total = model.speakerProfiles.count
        let shown = filteredProfiles.count
        let noun = total == 1 ? "speaker" : "speakers"
        return search.isEmpty ? "\(total) \(noun)" : "\(shown) of \(total)"
    }

    @ViewBuilder
    private var detail: some View {
        if let draft {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    SpeakerAvatar(name: draft.name.isEmpty ? "?" : draft.name, color: .accentColor, size: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.name.isEmpty ? "New Speaker" : draft.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Text(isNew ? "Not saved yet" : contactSummary(draft))
                            .font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("Name").gridColumnAlignment(.trailing)
                        ProfileField(title: "Name", prompt: "Full name", text: field(\.name))
                    }
                    GridRow {
                        Text("Email")
                        ProfileField(title: "Email", prompt: "Optional", text: field(\.email))
                    }
                    GridRow {
                        Text("Phone")
                        ProfileField(title: "Phone", prompt: "Optional", text: field(\.phone))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Contact details are shared across meetings. Names already in past meetings stay as saved.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.red)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    if dirty {
                        Text("Unsaved changes")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("Save or revert changes before selecting another speaker.")
                    }
                    if saving { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(isNew ? "Cancel" : "Revert") {
                        if isNew { selection = model.speakerProfiles.first?.id }
                        isNew = false
                        self.draft = original
                        error = nil
                    }
                    .disabled(!dirty)
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!dirty)
                }
            }
            .padding(20)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 36)).foregroundStyle(.tertiary)
                Text("No Speaker Selected").font(.headline)
                Text("Select a speaker or use + to add one.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func contactSummary(_ profile: SpeakerProfile) -> String {
        let contact = [profile.email, profile.phone].filter { !$0.isEmpty }.joined(separator: " · ")
        return contact.isEmpty ? "No contact details" : contact
    }

    private func field(_ key: WritableKeyPath<SpeakerProfile, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: key] ?? "" }, set: { draft?[keyPath: key] = $0 })
    }

    private func save() {
        guard let draft else { return }
        saving = true
        error = nil
        Task {
            do {
                try await model.saveSpeakerProfile(draft)
                isNew = false
                self.draft = original
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }

    private func delete() {
        guard let selection else { return }
        saving = true
        error = nil
        Task {
            do {
                try await model.deleteSpeakerProfile(selection)
                self.selection = model.speakerProfiles.first?.id
                draft = original
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}

/// A text field drawn on its own rounded fill, outlined only while focused. The native
/// rounded-border bezel leaves a visible seam at its corners on the card in dark mode.
private struct ProfileField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        // The system placeholder ignores SwiftUI styling and reads like a value on the fill,
        // so draw a dimmer one.
        TextField(title, text: $text, prompt: Text(""))
            .textFieldStyle(.plain)
            .labelsHidden()
            .focused($focused)
            .focusEffectDisabled()
            .accessibilityHint(prompt)
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.7), in: .rect(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.accentColor.opacity(focused ? 0.6 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .onTapGesture { focused = true }
    }
}

/// Learn Voices builds voiceprints from the speakers already linked to profiles and checks
/// itself against those tags; auto-tagging then links speakers whose voices match confidently.
private struct VoiceRecognitionSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            autoTagRow
            actions
        }
        .padding(18)
        .alert("Forget learned voices?", isPresented: $confirmingForget) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) { Task { await model.forgetVoices() } }
        } message: {
            Text("This removes every voiceprint Stillnote has read. Speaker tags, including ones matched by voice, are kept.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.wave.2.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice Recognition").font(.headline)
                status
            }
            Spacer(minLength: 12)
            if let voices = model.voiceModel, voices.calibrated {
                HStack(spacing: 8) {
                    MetricPill(
                        value: percent(voices.metrics.precision, roundDown: true), label: "accurate",
                        help: "Tested against your own tags, voice matches were right this often."
                    )
                    MetricPill(
                        value: percent(voices.metrics.coverage, roundDown: false), label: "covered",
                        help: "Share of tagged speakers that voice matching would have tagged. Uncertain speakers are left untagged."
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if let voices = model.voiceModel {
            let learned = Meeting.parseTimestamp(voices.learnedAt)?.formatted(date: .abbreviated, time: .omitted) ?? ""
            Text("\(voices.profileCount) \(voices.profileCount == 1 ? "voice" : "voices") from \(voices.meetingCount) \(voices.meetingCount == 1 ? "meeting" : "meetings") · Learned \(learned)")
                .font(.callout).foregroundStyle(.secondary)
            if !voices.calibrated {
                Text("Too few people appear in more than one meeting to measure accuracy yet, so only very close matches are tagged.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Learn each profile's voice from the speakers you've already linked, then let Stillnote tag new meetings for you.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let message = model.voiceStatusMessage, model.voiceJob == nil {
            Text(message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var autoTagRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-tag speakers after transcription")
                Text(model.voiceModel == nil
                     ? "Learn voices first to turn this on."
                     : "Links confident matches. Speakers you've tagged are never changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Auto-tag speakers after transcription", isOn: Binding(
                get: { model.settings.speakerRecognition.autoTagAfterTranscription },
                set: { value in
                    guard value != model.settings.speakerRecognition.autoTagAfterTranscription else { return }
                    var updated = model.settings
                    updated.speakerRecognition.autoTagAfterTranscription = value
                    Task { await model.saveSettings(updated) }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .disabled(model.voiceModel == nil)
    }

    @ViewBuilder
    private var actions: some View {
        if let job = model.voiceJob {
            HStack(spacing: 10) {
                if let fraction = job.fraction {
                    ProgressView(value: fraction).frame(maxWidth: 200)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(job.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Stop") { model.cancelVoiceJob() }
            }
        } else {
            HStack(spacing: 8) {
                Button(model.voiceModel == nil ? "Learn Voices" : "Relearn Voices") { model.learnVoices() }
                    .help("Read the voices of speakers you've linked to profiles")
                Button("Auto-Tag All Meetings") { model.autoTagLibrary() }
                    .disabled(model.voiceModel == nil)
                    .help("Link untagged speakers in every transcribed meeting. Speakers you've tagged are never changed.")
                Spacer()
                Label("On-device · \(megabytes) MB model", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Voices are read on this Mac and never leave it. The first run downloads a \(megabytes) MB voice model.")
                if model.voiceModel != nil {
                    Menu {
                        Button("Forget Voices…", role: .destructive) { confirmingForget = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More voice options")
                    .accessibilityLabel("More voice options")
                }
            }
        }
    }

    private var megabytes: Int { (try? SpeechCatalog.spec(SpeechCatalog.speakerModel))?.downloadMegabytes ?? 15 }

    private func percent(_ value: Double, roundDown: Bool) -> String {
        let scaled = value * 100
        return "\(Int(roundDown ? scaled.rounded(.down) : scaled.rounded()))%"
    }
}

private struct MetricPill: View {
    let value: String
    let label: String
    let help: String

    var body: some View {
        VStack(spacing: 0) {
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minWidth: 58)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityHint(help)
    }
}

private extension View {
    func settingsCard() -> some View { modifier(SettingsCard()) }
}

/// A soft grouped-form style surface, separated by tone rather than outlines. Increased
/// contrast restores the outline, matching `contentPanel`.
private struct SettingsCard: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .clipShape(.rect(cornerRadius: 12))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}
