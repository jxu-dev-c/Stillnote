import StillnoteCore
import SwiftUI

extension MeetingStatus {
    var label: String {
        switch self {
        case .ready: return "Recorded"
        case .transcribing: return "Transcribing"
        case .transcribed: return "Transcribed"
        case .summarizing: return "Summarizing"
        case .complete: return "Complete"
        case .error: return "Needs attention"
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "waveform"
        case .transcribing, .summarizing: return "arrow.triangle.2.circlepath"
        case .transcribed: return "text.alignleft"
        case .complete: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .complete: return .green
        case .error: return .orange
        default: return .secondary
        }
    }
}

struct MeetingStatusLabel: View {
    let status: MeetingStatus
    var font: Font = .caption.weight(.medium)

    var body: some View {
        HStack(spacing: 6) {
            if status.isBusy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: status.symbol)
            }
            Text(status.label)
        }
        .font(font)
        .foregroundStyle(status.tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(status.tint.opacity(0.10), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// Speaker colors come from the system palette so they stay legible in both
/// appearances and under Increase Contrast.
enum SpeakerTint {
    static let palette: [Color] = [.blue, .green, .orange, .purple, .teal]

    static func color(for speaker: String, in meeting: Meeting) -> Color {
        let index = meeting.orderedSpeakerIDs().firstIndex(of: speaker) ?? abs(speaker.hashValue)
        return palette[index % palette.count]
    }
}

struct SpeakerAvatar: View {
    let name: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        Text(String(name.first.map(String.init)?.uppercased() ?? "?"))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.18), in: .circle)
    }
}

extension View {
    /// Presents a thrown message without inventing a second error surface.
    func reportingTask(_ operation: @escaping () async -> Void) -> some View {
        task { await operation() }
    }
}

extension Binding {
    /// Bridges an optional selection into the non-optional bindings pickers expect.
    func replacingNil<T>(with value: T) -> Binding<T> where Value == T? {
        Binding<T>(get: { wrappedValue ?? value }, set: { wrappedValue = $0 })
    }
}

let transcriptionLanguages: [(code: String, name: String)] = [
    ("auto", "Detect automatically"), ("en", "English"), ("es", "Spanish"), ("fr", "French"),
    ("de", "German"), ("it", "Italian"), ("pt", "Portuguese"), ("zh", "Chinese"), ("ja", "Japanese"),
    ("ko", "Korean"), ("ar", "Arabic"), ("hi", "Hindi"), ("nl", "Dutch"), ("ru", "Russian"),
]

/// Language and speaker-count hints, shared by the recording, import, and re-transcribe forms.
struct TranscriptionOptionFields: View {
    @Binding var language: String
    @Binding var speakerCount: Int?

    var body: some View {
        Picker("Language", selection: $language) {
            ForEach(transcriptionLanguages, id: \.code) { Text($0.name).tag($0.code) }
        }
        Picker("Speakers", selection: $speakerCount) {
            Text("Detect automatically").tag(Int?.none)
            ForEach(1...10, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
        }
    }
}
