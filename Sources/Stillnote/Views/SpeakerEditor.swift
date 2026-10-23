import StillnoteCore
import SwiftUI

/// Meeting assignment stays separate from profile management in Settings.
struct SpeakerEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    let meetingID: String
    let speakerID: String

    @State private var selectedProfileID: String?
    @State private var profileSearch = ""
    @FocusState private var searchFocused: Bool
    @State private var error: String?
    @State private var saving = false

    private var meeting: Meeting? { model.meeting(meetingID) }
    private var selectedProfile: SpeakerProfile? {
        model.speakerProfiles.first { $0.id == selectedProfileID }
    }
    private var matchingProfiles: [SpeakerProfile] {
        let query = profileSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.speakerProfiles }
        return model.speakerProfiles.filter { profile in
            [profile.name, profile.email, profile.phone].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }
    private var unavailable: Bool { saving || meeting == nil || meeting?.status.isBusy == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Speaker profile").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Edit Profiles") {
                        model.requestedSpeakerProfileID = selectedProfile?.id
                        model.settingsTab = "speakers"
                        dismiss()
                        openSettings()
                    }
                    .help("Open speaker profile settings")
                }
                if model.speakerProfiles.isEmpty {
                    Text("Add speaker profiles in Settings → Speakers.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    TextField("Search by name, email, or phone", text: $profileSearch)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search speaker profiles")
                        .focused($searchFocused)
                        .disabled(unavailable)
                        .onChange(of: profileSearch) {
                            // A hidden selection must never remain assignable after filtering.
                            if !matchingProfiles.contains(where: { $0.id == selectedProfileID }) {
                                selectedProfileID = nil
                            }
                        }
                    List(selection: $selectedProfileID) {
                        ForEach(matchingProfiles) { profile in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name)
                                if !profile.email.isEmpty {
                                    Text(profile.email).font(.caption).foregroundStyle(.secondary)
                                } else if !profile.phone.isEmpty {
                                    Text(profile.phone).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                            .tag(profile.id)
                        }
                    }
                    .listStyle(.bordered)
                    .frame(height: 200)
                    .accessibilityLabel("Matching speaker profiles")
                    .disabled(unavailable)
                    .overlay {
                        if matchingProfiles.isEmpty {
                            Text("No matching speaker profiles")
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            Divider()
            HStack(spacing: 10) {
                if meeting?.speakerProfiles[speakerID] != nil {
                    Button("Unlink") { assign(nil) }
                        .help("Remove the profile link and keep the meeting’s speaker name")
                }
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Assign") { assign(selectedProfileID) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedProfile == nil)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .disabled(unavailable)
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled(saving)
        .onAppear {
            selectedProfileID = meeting?.speakerProfiles[speakerID]
            searchFocused = true
        }
    }

    private func assign(_ id: String?) {
        saving = true
        error = nil
        Task {
            do {
                try await model.assignSpeakerProfile(id, meetingID: meetingID, speakerID: speakerID)
                dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
