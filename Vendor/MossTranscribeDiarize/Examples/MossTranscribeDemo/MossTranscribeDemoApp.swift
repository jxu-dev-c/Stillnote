import SwiftUI
import MossTranscribeDiarize

/// Minimal macOS SwiftUI demo hosting the full `TranscribeView` studio.
@main
struct MossTranscribeDemoApp: App {
    var body: some Scene {
        WindowGroup("MOSS Transcribe Demo") {
            ContentView()
        }
        .defaultSize(width: 720, height: 880)
    }
}

struct ContentView: View {
    var body: some View {
        TranscribeView()
            .frame(minWidth: 560, minHeight: 640)
    }
}

#Preview {
    ContentView()
}
