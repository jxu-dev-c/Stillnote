import StillnoteCore
import SwiftUI

@main
struct StillnoteApp: App {
    init() {
        // `Stillnote --diagnose` reports where the app resolved its data, model, and
        // MOSS runtime paths, which is the fastest way to check a fresh install.
        if CommandLine.arguments.contains("--diagnose") {
            print(Diagnostics.report())
            exit(0)
        }
    }

    @State private var model = AppModel()
    @State private var sheet: RootSheet?

    var body: some Scene {
        WindowGroup {
            RootView(sheet: $sheet)
                .environment(model)
                .task { await model.load() }
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording…") { sheet = .record }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Import Audio…") { sheet = .importAudio }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Link("MOSS speech model", destination: URL(string: "https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize")!)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 520)
        }
    }
}

enum RootSheet: String, Identifiable {
    case record, importAudio
    var id: String { rawValue }
}
