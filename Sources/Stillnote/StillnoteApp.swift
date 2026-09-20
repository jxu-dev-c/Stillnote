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
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording…") { sheet = .record }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.isReady)
                Button("Import Audio…") { sheet = .importAudio }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(!model.isReady)
            }
            CommandGroup(replacing: .help) {
                Link("MOSS speech model", destination: URL(string: "https://huggingface.co/OpenMOSS-Team/MOSS-Transcribe-Diarize")!)
            }
        }

        Settings {
            Group {
                if model.isReady {
                    SettingsView()
                } else {
                    Text("Your library is still opening. Return to the main window for status.")
                        .padding()
                }
            }
                .environment(model)
                .frame(width: 640)
        }
    }
}

enum RootSheet: String, Identifiable {
    case record, importAudio
    var id: String { rawValue }
}
