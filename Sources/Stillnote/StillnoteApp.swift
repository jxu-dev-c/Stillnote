import StillnoteCore
import SwiftUI

@main
struct StillnoteApp: App {
    init() {
        // `Stillnote --diagnose` reports where the app resolved its data, model, and
        // speech runtime paths, which is the fastest way to check a fresh install.
        if CommandLine.arguments.contains("--diagnose") {
            print(Diagnostics.report())
            exit(0)
        }
    }

    /// A single main window, so the menu bar's Open Stillnote brings it forward rather than
    /// opening another. The menu bar extra keeps the app running once it is closed.
    static let mainWindowID = "main"

    @State private var model = AppModel()
    @State private var sheet: RootSheet?

    var body: some Scene {
        Window("Stillnote", id: Self.mainWindowID) {
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
                Link("Nemotron 3.5 ASR model", destination: URL(string: "https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b")!)
                Link("Nemotron 3 Diarization model", destination: URL(string: "https://huggingface.co/nvidia/Nemotron-3-Diarization")!)
            }
        }

        MenuBarExtra {
            MenuBarMenu()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
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
