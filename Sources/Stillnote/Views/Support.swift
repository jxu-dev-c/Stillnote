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
