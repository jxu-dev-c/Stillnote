import StillnoteCore
import SwiftUI

/// Voice recognition and auto-tagging. Learn Voices builds voiceprints from the speakers already
/// linked to profiles and checks itself against those tags; auto-tagging then links speakers whose
/// voices match confidently.
struct SpeakersSettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingForget = false

    var body: some View {
        SettingsSection("Voice recognition") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    notes
                    if let voices = model.voiceModel, voices.calibrated {
                        HStack(spacing: 10) {
                            metric(percent(voices.metrics.precision, roundDown: true), "accurate",
                                   help: "Tested against your own tags, voice matches were right this often.")
                            metric(percent(voices.metrics.coverage, roundDown: false), "covered",
                                   help: "Share of tagged speakers that voice matching would have tagged. Uncertain speakers are left untagged.")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 14)

                actions
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .alert("Forget learned voices?", isPresented: $confirmingForget) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) { Task { await model.forgetVoices() } }
        } message: {
            Text("This removes every voiceprint Stillnote has read. Speaker tags, including ones matched by voice, are kept.")
        }

        SettingsSection("Auto-tagging") {
            SettingsCard {
                SettingsRow(
                    "Auto-tag speakers after transcription",
                    caption: model.voiceModel == nil
                        ? "Learn voices first to turn this on."
                        : "Links confident matches. Speakers you’ve tagged are never changed."
                ) {
                    SettingsSwitch("Auto-tag speakers after transcription",
                                   isOn: model.setting(\.speakerRecognition.autoTagAfterTranscription))
                }
                .disabled(model.voiceModel == nil)
                SettingsRow(
                    "Tag meetings you already have",
                    caption: "Links untagged speakers in every transcribed meeting. Speakers you’ve tagged are never changed."
                ) {
                    Button("Auto-Tag All Meetings") { model.autoTagLibrary() }
                        .buttonStyle(.settings)
                        .disabled(model.voiceModel == nil || model.voiceJob != nil)
                }
            }
        }

        Button { model.settingsPage = .people } label: {
            HStack(spacing: 12) {
                Text("Edit contact details in People")
                    .font(SettingsMetrics.rowFont)
                    .foregroundStyle(DS.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Icon(.next, size: 12, lineWidth: 2.2).foregroundStyle(DS.text2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(DS.card, in: .rect(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                    .strokeBorder(DS.cardBorder, lineWidth: 0.5)
            }
            .contentShape(.rect(cornerRadius: SettingsMetrics.cardRadius))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 14) {
            SettingsIconTile(icon: .voice)
            VStack(alignment: .leading, spacing: 3) {
                if let voices = model.voiceModel {
                    Text("\(voices.profileCount) \(voices.profileCount == 1 ? "voice" : "voices") from \(voices.meetingCount) \(voices.meetingCount == 1 ? "meeting" : "meetings")")
                        .font(.system(size: 15, weight: .semibold))
                    let learned = Meeting.parseTimestamp(voices.learnedAt)?.formatted(date: .abbreviated, time: .omitted)
                    if let learned {
                        Text("Learned \(learned)").font(SettingsMetrics.captionFont).foregroundStyle(DS.text2)
                    }
                } else {
                    Text("No voices learned yet").font(.system(size: 15, weight: .semibold))
                    Text("Learn each profile’s voice from the speakers you’ve already linked, then let Stillnote tag new meetings for you.")
                        .font(SettingsMetrics.captionFont)
                        .foregroundStyle(DS.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.voiceModel != nil {
                Menu {
                    Button("Forget Voices…", role: .destructive) { confirmingForget = true }
                } label: {
                    Icon(.more, size: 16, filled: true)
                        .foregroundStyle(DS.text2)
                        .frame(width: 28, height: 28)
                        .contentShape(.circle)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .hoverFill(.circle, color: DS.settingsHover)
                .help("More voice recognition options")
                .accessibilityLabel("More voice recognition options")
                .disabled(model.voiceJob != nil)
            }
        }
    }

    @ViewBuilder
    private var notes: some View {
        if let voices = model.voiceModel, !voices.calibrated {
            SettingsCaption("Too few people appear in more than one meeting to measure accuracy yet, so only very close matches are tagged.")
        }
        if let message = model.voiceStatusMessage, model.voiceJob == nil {
            SettingsCaption(message)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let job = model.voiceJob {
            HStack(spacing: 10) {
                if let fraction = job.fraction {
                    ProgressView(value: fraction).frame(maxWidth: 200).tint(DS.accent)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(job.detail)
                    .font(SettingsMetrics.captionFont)
                    .foregroundStyle(DS.text2)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Stop") { model.cancelVoiceJob() }
                    .buttonStyle(.settings)
            }
        } else {
            HStack(spacing: 8) {
                Label {
                    Text("On-device · \(megabytes) MB model")
                } icon: {
                    Icon(.lock, size: 13, lineWidth: 1.9)
                }
                .font(SettingsMetrics.captionFont)
                .foregroundStyle(DS.text2)
                .help("Voices are read on this Mac and never leave it. The first run downloads a \(megabytes) MB voice model.")
                Spacer(minLength: 0)
                Button(model.voiceModel == nil ? "Learn Voices" : "Relearn Voices") { model.learnVoices() }
                    .buttonStyle(.settings)
                    .help("Read the voices of speakers you’ve linked to profiles")
            }
        }
    }

    private func metric(_ value: String, _ label: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .bold))
                .letterSpacing(-0.02, size: 24)
                .monospacedDigit()
                .foregroundStyle(DS.text)
            Text(label).font(SettingsMetrics.captionFont).foregroundStyle(DS.text2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.well, in: .rect(cornerRadius: 12, style: .continuous))
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityHint(help)
    }

    private var megabytes: Int { (try? SpeechCatalog.spec(SpeechCatalog.speakerModel))?.downloadMegabytes ?? 15 }

    private func percent(_ value: Double, roundDown: Bool) -> String {
        let scaled = value * 100
        return "\(Int(roundDown ? scaled.rounded(.down) : scaled.rounded()))%"
    }
}
