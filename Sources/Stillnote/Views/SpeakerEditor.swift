import StillnoteCore
import SwiftUI

/// Meeting assignment stays separate from profile management in Settings.
struct SpeakerEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    let meetingID: String
    let speakerID: String

    @State private var selectedProfileID = ""
    @State private var error: String?
    @State private var saving = false

    private var meeting: Meeting? { model.meeting(meetingID) }
    private var selectedProfile: SpeakerProfile? {
        model.speakerProfiles.first { $0.id == selectedProfileID }
    }
    private var unavailable: Bool { saving || meeting == nil || meeting?.status.isBusy == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Speaker profile").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Picker("", selection: $selectedProfileID) {
                        Text("Select a speaker").tag("")
                        ForEach(model.speakerProfiles) { profile in
                            Text(profile.email.isEmpty ? profile.name : "\(profile.name) · \(profile.email)")
                                .tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Speaker profile")
                    Button("Edit Profile") {
                        guard let profile = selectedProfile else { return }
                        model.requestedSpeakerProfileID = profile.id
                        model.settingsTab = "speakers"
                        dismiss()
                        openSettings()
                    }
                    .disabled(selectedProfile == nil)
                }
                if model.speakerProfiles.isEmpty {
                    Text("Add speaker profiles in Settings → Speakers.")
                        .font(.callout).foregroundStyle(.secondary)
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
        }
        .padding(24)
        .frame(width: 420)
        .disabled(unavailable)
        .interactiveDismissDisabled(saving)
        .onAppear { selectedProfileID = meeting?.speakerProfiles[speakerID] ?? "" }
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
