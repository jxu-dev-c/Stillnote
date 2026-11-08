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
        VStack(alignment: .leading, spacing: 16) {
            profileEditor
            Divider()
            VoiceRecognitionSection()
        }
        .padding(20)
    }

    private var profileEditor: some View {
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

/// Learn Voices builds voiceprints from the speakers already linked to profiles and checks
/// itself against those tags; auto-tagging then links speakers whose voices match confidently.
private struct VoiceRecognitionSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Voice Recognition").font(.headline)
            status
            if let job = model.voiceJob {
                HStack(spacing: 10) {
                    if let fraction = job.fraction {
                        ProgressView(value: fraction).frame(maxWidth: 220)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(job.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Stop") { model.cancelVoiceJob() }
                }
            } else {
                HStack(spacing: 10) {
                    Button(model.voiceModel == nil ? "Learn Voices" : "Relearn Voices") { model.learnVoices() }
                        .help("Read the voices of speakers you've linked to profiles")
                    Button("Auto-Tag All Meetings") { model.autoTagLibrary() }
                        .disabled(model.voiceModel == nil)
                        .help("Link untagged speakers in every transcribed meeting. Speakers you've tagged are never changed.")
                    Spacer()
                    if model.voiceModel != nil {
                        Button("Forget Voices…") { confirmingForget = true }
                            .buttonStyle(.borderless)
                    }
                }
            }
            if let message = model.voiceStatusMessage, model.voiceJob == nil {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Toggle("Auto-tag speakers after transcription", isOn: Binding(
                get: { model.settings.speakerRecognition.autoTagAfterTranscription },
                set: { value in
                    guard value != model.settings.speakerRecognition.autoTagAfterTranscription else { return }
                    var updated = model.settings
                    updated.speakerRecognition.autoTagAfterTranscription = value
                    Task { await model.saveSettings(updated) }
                }
            ))
            .disabled(model.voiceModel == nil)
            Text("Voices are read on this Mac and never leave it. The first run downloads a \(megabytes) MB voice model.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("Forget learned voices?", isPresented: $confirmingForget) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) { Task { await model.forgetVoices() } }
        } message: {
            Text("This removes every voiceprint Stillnote has read. Speaker tags, including ones matched by voice, are kept.")
        }
    }

    private var megabytes: Int { (try? SpeechCatalog.spec(SpeechCatalog.speakerModel))?.downloadMegabytes ?? 15 }

    @ViewBuilder
    private var status: some View {
        if let voices = model.voiceModel {
            let learned = Meeting.parseTimestamp(voices.learnedAt)?.formatted(date: .abbreviated, time: .omitted) ?? ""
            VStack(alignment: .leading, spacing: 3) {
                Text("Learned \(voices.profileCount) \(voices.profileCount == 1 ? "voice" : "voices") from \(voices.meetingCount) \(voices.meetingCount == 1 ? "meeting" : "meetings") · \(learned)")
                    .font(.callout)
                Text(accuracy(voices)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Stillnote can learn each profile's voice from the speakers you've already linked, then tag new meetings for you.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func accuracy(_ voices: VoiceModel) -> String {
        guard voices.calibrated else {
            return "Too few people appear in more than one meeting to measure accuracy yet, so only very close matches are tagged."
        }
        let precision = Int((voices.metrics.precision * 100).rounded(.down))
        let coverage = Int((voices.metrics.coverage * 100).rounded())
        return "Tested against your own tags, matches were right \(precision)% of the time and covered \(coverage)% of speakers. Uncertain speakers are left untagged."
    }
}
