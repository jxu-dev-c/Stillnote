// Synthetic, no-op toolbar fixture for visual/accessibility verification.
// Compile with the same sources and linkage as scripts/check-library-model.sh.
import AppKit
import SwiftUI
import StillnoteCore

enum StillnoteApp { static let mainWindowID = "main" }
enum RootSheet: String, Identifiable { case record, importAudio; var id: String { rawValue } }

struct ToolbarFixture: View {
    @State private var page: MeetingPage = .summary
    @State private var query = ""
    @State private var dark = true
    @State private var compact = false
    @State private var contrast = false
    @State private var lastAction = "No action performed"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DetailToolbar(actions: [
                ToolbarAction(icon: .nameMeeting, symbol: "wand.and.sparkles", label: "Name Meeting") { lastAction = "Name Meeting" },
                ToolbarAction(icon: .autoTag, symbol: "wand.and.stars", label: "Auto-Tag Speakers",
                              help: "Learn voices in Settings → Speakers first.", enabled: false) {},
                ToolbarAction(icon: .transcribeAgain, symbol: "waveform.badge.magnifyingglass", label: "Transcribe Again…") { lastAction = "Transcribe Again" },
                ToolbarAction(icon: .regenerate, symbol: "arrow.triangle.2.circlepath", label: "Regenerate Summary") { lastAction = "Regenerate Summary" },
            ], actionsEnabled: true, deleteEnabled: true, page: $page, query: $query, onSearch: { _ in }) {
                ToolbarIconButton(icon: .trash, label: "Delete Meeting", tint: DS.danger) { lastAction = "Delete Meeting" }
            }
            .frame(width: compact ? 550 : 1000)
            VStack(alignment: .leading, spacing: 12) {
                Text("Product planning").font(.largeTitle.bold())
                Text("Synthetic meeting · Toolbar accessibility preview").foregroundStyle(DS.text2)
                Text("Explore the toolbar using the pointer or keyboard. Actions are harmless in this fixture.")
                Spacer()
                Text(lastAction).font(.caption)
                HStack {
                    Toggle("Dark appearance", isOn: $dark)
                    Toggle("Compact toolbar", isOn: $compact)
                    Toggle("High-contrast appearance", isOn: $contrast)
                }
            }
            .padding(28)
        }
        .frame(width: 1000, height: 400)
        .foregroundStyle(DS.text)
        .background(DS.windowSolid)
        .environment(\.colorScheme, dark ? .dark : .light)
        .onChange(of: contrast) { _, _ in updateAppearance() }
        .onChange(of: dark) { _, _ in updateAppearance() }
    }

    private func updateAppearance() {
        NSApp.windows.first?.appearance = NSAppearance(named: contrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua))
    }
}

@main struct ToolbarPreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Stillnote — Toolbar Preview"
        window.contentView = NSHostingView(rootView: ToolbarFixture())
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()
        app.run()
    }
}
