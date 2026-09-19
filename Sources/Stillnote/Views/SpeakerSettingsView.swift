import StillnoteCore
import SwiftUI

/// Standard macOS master/detail editor. Selection exposes fields directly.
struct SpeakerSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var draft: SpeakerProfile?
    @State private var isNew = false
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingDelete = false

    private var original: SpeakerProfile? {
        model.speakerProfiles.first { $0.id == selection }
    }
    private var dirty: Bool { draft != nil && (isNew || draft != original) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.speakerProfiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                    if isNew, let draft {
                        Text(draft.name.isEmpty ? "New Speaker" : draft.name).tag(draft.id)
                    }
                }
                .listStyle(.bordered)
                .disabled(saving || dirty)
                Divider()
                HStack(spacing: 0) {
                    Button {
                        let profile = SpeakerProfile(name: "")
                        isNew = true
                        selection = profile.id
                        draft = profile
                        error = nil
                    } label: { Image(systemName: "plus").frame(width: 24, height: 22) }
                    .help("Add speaker profile")
                    .accessibilityLabel("Add speaker profile")
                    .disabled(saving || dirty)
                    Divider().frame(height: 16)
                    Button {
                        confirmingDelete = true
                    } label: { Image(systemName: "minus").frame(width: 24, height: 22) }
                    .help("Delete speaker profile")
                    .accessibilityLabel("Delete speaker profile")
                    .disabled(saving || selection == nil || dirty)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
                .background(.quaternary.opacity(0.3))
            }
            .frame(width: 175)
            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 16) {
                if draft != nil {
                    Text(isNew ? "New Speaker" : "Speaker Details").font(.headline)
                    Form {
                        TextField("Name", text: field(\.name))
                        TextField("Email", text: field(\.email), prompt: Text("Optional"))
                        TextField("Phone", text: field(\.phone), prompt: Text("Optional"))
                    }
                    .textFieldStyle(.roundedBorder)
                    Text("Contact details are shared across meetings. Existing meeting names stay as saved.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error { Text(error).font(.callout).foregroundStyle(.red) }
                    Spacer()
                    HStack {
                        Spacer()
                        Button(isNew ? "Cancel" : "Revert") {
                            if isNew { selection = nil }
                            isNew = false
                            draft = original
                            error = nil
                        }.disabled(!dirty)
                        Button("Save") { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!dirty)
                    }
                    if dirty {
                        Text("Save or revert changes before selecting another speaker.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Spacer()
                    Text("Select a speaker or use + to add one.")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .disabled(saving)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
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
