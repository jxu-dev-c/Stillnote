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
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Assign Speaker").font(.title2.weight(.semibold))
                        Text("Choose a profile for this voice.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit Profiles") {
                        model.requestedSpeakerProfileID = selectedProfile?.id
                        model.settingsTab = "speakers"
                        dismiss()
                        openSettings()
                    }
                    .controlSize(.small)
                    .help("Open speaker profile settings")
                }
                if model.speakerProfiles.isEmpty {
                    Text("Add speaker profiles in Settings → Speakers.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("Search name, email, or phone", text: $profileSearch)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Search speaker profiles")
                            .focused($searchFocused)
                        if !profileSearch.isEmpty {
                            Button {
                                profileSearch = ""
                                searchFocused = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .font(.body)
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(searchFocused ? Color.accentColor.opacity(0.65) : .clear, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                    .disabled(unavailable)
                    .onChange(of: profileSearch) {
                        // A hidden selection must never remain assignable after filtering.
                        if !matchingProfiles.contains(where: { $0.id == selectedProfileID }) {
                            selectedProfileID = nil
                        }
                    }
                    List(selection: $selectedProfileID) {
                        ForEach(matchingProfiles) { profile in
                            HStack(spacing: 12) {
                                SpeakerAvatar(name: profile.name, color: .primary, size: 36)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name).font(.body.weight(.medium)).lineLimit(1)
                                    let contact = [profile.email, profile.phone].filter { !$0.isEmpty }.joined(separator: " · ")
                                    if !contact.isEmpty {
                                        Text(contact).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                if selectedProfileID == profile.id {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                            .padding(.vertical, 2)
                            .tag(profile.id)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .frame(height: matchingProfiles.isEmpty ? 112 : CGFloat(min(matchingProfiles.count, 5)) * 56 + 16)
                    .accessibilityLabel("Matching speaker profiles")
                    .disabled(unavailable)
                    .overlay {
                        if matchingProfiles.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "person.crop.circle.badge.questionmark")
                                    .font(.title2).foregroundStyle(.tertiary)
                                Text("No matching speakers").font(.body.weight(.medium))
                                Text("Try a different name, email, or phone.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack(spacing: 10) {
                if meeting?.speakerProfiles[speakerID] != nil {
                    Button("Unlink") { assign(nil) }
                        .buttonStyle(.borderless)
                        .help("Remove the profile link and keep the meeting’s speaker name")
                }
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Assign") { assign(selectedProfileID) }
                    .primaryActionStyle()
                    .disabled(selectedProfile == nil)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .disabled(unavailable)
        }
        .padding(24)
        .frame(width: 460)
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
