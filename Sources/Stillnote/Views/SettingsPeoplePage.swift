import StillnoteCore
import SwiftUI

/// Speaker profiles as a searchable list beside the selected person's contact details.
struct PeopleSettingsPage: View {
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
        HStack(alignment: .top, spacing: 20) {
            list
                .frame(width: 228)
                .frame(maxHeight: .infinity)
            detail
                .disabled(saving)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            selection = model.requestedSpeakerProfileID ?? model.speakerProfiles.first?.id
            draft = original
            model.requestedSpeakerProfileID = nil
        }
        .onChange(of: model.requestedSpeakerProfileID) {
            guard let requested = model.requestedSpeakerProfileID else { return }
            if dirty {
                error = "Save or revert your changes before switching people."
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
        .alert("Remove this person?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { delete() }
        } message: {
            Text("Remove \(original?.name ?? "this person") and their contact details? Meeting names and summaries will be kept.")
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                searchField
                Button(action: addPerson) {
                    Icon(.plus, size: 14, lineWidth: 1.8)
                        .foregroundStyle(DS.text)
                        .frame(width: 36, height: 36)
                        .background(DS.peopleField, in: .rect(cornerRadius: 10, style: .continuous))
                        .hoverFill(.rect(cornerRadius: 10, style: .continuous), color: DS.settingsHover)
                }
                .buttonStyle(.plain)
                .help("Add person")
                .accessibilityLabel("Add person")
                .disabled(saving || dirty)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    if isNew, let draft {
                        row(id: draft.id, name: draft.name.isEmpty ? "New Person" : draft.name)
                    }
                    ForEach(filteredProfiles) { profile in
                        row(id: profile.id, name: profile.name)
                    }
                    if filteredProfiles.isEmpty && !isNew {
                        Text(search.isEmpty ? "No people yet. Use + to add one." : "No one matches that search.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(DS.text2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                    }
                }
            }
            .scrollIndicators(.never)
            .disabled(saving || dirty)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("People")
            Text(countLabel)
                .font(SettingsMetrics.captionFont)
                .monospacedDigit()
                .foregroundStyle(DS.text2)
                .padding(.horizontal, 10)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Icon(.search, size: 14, lineWidth: 2.2).foregroundStyle(DS.text2)
            TextField("Search people", text: $search, prompt: Text("Search people"))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($searchFocused)
                .focusEffectDisabled()
            if !search.isEmpty {
                Button {
                    search = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(DS.text3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(DS.peopleField, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(searchFocused ? DS.accent.opacity(0.6) : .clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .contentShape(.rect)
        .onTapGesture { searchFocused = true }
    }

    private func row(id: String, name: String) -> some View {
        let selected = selection == id
        return Button { selection = id } label: {
            HStack(spacing: 10) {
                PersonAvatar(name: name, accent: .stable(id))
                Text(name)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(selected ? DS.peopleSelection : .clear, in: .rect(cornerRadius: 10, style: .continuous))
            .hoverFill(.rect(cornerRadius: 10, style: .continuous), color: DS.settingsHover)
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var countLabel: String {
        let total = model.speakerProfiles.count
        let noun = total == 1 ? "person" : "people"
        return search.isEmpty ? "\(total) \(noun)" : "\(filteredProfiles.count) of \(total)"
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let draft {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    PersonAvatar(name: draft.name.isEmpty ? "?" : draft.name, accent: .stable(draft.id), size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(draft.name.isEmpty ? "New Person" : draft.name)
                            .font(.system(size: 17, weight: .semibold))
                            .letterSpacing(-0.01, size: 17)
                            .lineLimit(1)
                        Text(isNew ? "Not saved yet" : contactSummary(draft))
                            .font(SettingsMetrics.captionFont)
                            .foregroundStyle(DS.text2)
                            .lineLimit(1)
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    PersonField(title: "Name", prompt: "Full name", text: field(\.name))
                    PersonField(title: "Email", prompt: "Optional", text: field(\.email))
                    PersonField(title: "Phone", prompt: "Optional", text: field(\.phone))
                    SettingsCaption("Contact details are shared across meetings. Names already in past meetings stay as saved.")
                    if let error {
                        SettingsNotice(text: error, color: DS.danger)
                    }
                }

                HStack(spacing: 8) {
                    Button("Remove Person") { confirmingDelete = true }
                        .buttonStyle(RemoveButtonStyle())
                        .disabled(selection == nil || isNew || dirty)
                    Spacer(minLength: 0)
                    if dirty {
                        Text("Unsaved changes")
                            .font(SettingsMetrics.captionFont)
                            .foregroundStyle(DS.text2)
                            .help("Save or revert changes before selecting another person.")
                    }
                    if saving { ProgressView().controlSize(.small) }
                    Button(isNew ? "Cancel" : "Revert") {
                        if isNew { selection = model.speakerProfiles.first?.id }
                        isNew = false
                        self.draft = original
                        error = nil
                    }
                    .buttonStyle(PanelButtonStyle(prominent: false))
                    .disabled(!dirty)
                    Button("Save") { save() }
                        .buttonStyle(PanelButtonStyle(prominent: dirty))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!dirty)
                }
            }
            .padding(24)
            .background(DS.peoplePanel, in: .rect(cornerRadius: 18, style: .continuous))
            .modifier(PanelShadow())
        } else {
            VStack(spacing: 8) {
                Icon(.people, size: 36, lineWidth: 1.5).foregroundStyle(DS.text3)
                Text("No Person Selected").font(.headline)
                Text("Select someone or use + to add a person.")
                    .font(.callout).foregroundStyle(DS.text2)
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

    private func addPerson() {
        let profile = SpeakerProfile(name: "")
        search = ""
        isNew = true
        selection = profile.id
        draft = profile
        error = nil
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

/// A labelled field on its own rounded fill, outlined only while focused. The system
/// placeholder reads like a value on the fill, so a dimmer one is drawn.
private struct PersonField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.text2)
                .accessibilityHidden(true)
            TextField(title, text: $text, prompt: Text(""))
                .textFieldStyle(.plain)
                .labelsHidden()
                .font(.system(size: 13.5))
                .focused($focused)
                .focusEffectDisabled()
                .accessibilityHint(prompt)
                .overlay(alignment: .leading) {
                    if text.isEmpty {
                        Text(prompt)
                            .font(.system(size: 13.5))
                            .foregroundStyle(DS.text3)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(DS.peopleInput, in: .rect(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(DS.accent.opacity(focused ? 0.6 : 0), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
                .contentShape(.rect)
                .onTapGesture { focused = true }
        }
    }
}

/// Revert and Save: 32 points tall, at least 80 wide. A prominent one is filled with the accent.
private struct PanelButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? Color.white : isEnabled ? DS.text : DS.text3)
            .padding(.horizontal, 16)
            .frame(minWidth: 80)
            .frame(height: 32)
            .background(prominent ? DS.save : isEnabled ? DS.peopleInput : DS.buttonOff,
                        in: .rect(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(.rect(cornerRadius: 9))
    }
}

private struct RemoveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(DS.danger)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .hoverFill(.rect(cornerRadius: 9, style: .continuous), color: DS.settingsHover)
            .padding(.leading, -10)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
    }
}

/// The light panel's soft shadow; the dark panel has none.
private struct PanelShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .shadow(color: scheme == .dark ? .clear : .black.opacity(0.04), radius: 1, y: 1)
            .shadow(color: scheme == .dark ? .clear : Color(nsColor: .rgba(40, 50, 90, 0.07)), radius: 12, y: 8)
    }
}
