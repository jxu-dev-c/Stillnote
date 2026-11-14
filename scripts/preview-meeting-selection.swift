// Exercises production rows without database, model, or provider startup.
// Build with preview-meeting-selection.sh, then open the printed app path.
// Select rows 1 → 0 → 2 → 1: exactly one row must have a blue fill and AXSelected,
// matching the ID at right. Scroll it out of view and back; selection must persist.
import AppKit
import SwiftUI
import StillnoteCore

enum StillnoteApp { static let mainWindowID = "main" }
enum RootSheet: String, Identifiable { case record, importAudio; var id: String { rawValue } }

private struct SelectionFixture: View {
    @State private var selection: String?

    var body: some View {
        HStack {
            SelectionRows(selection: $selection)
            Text(selection ?? "No selection").frame(width: 200)
        }
    }
}

// Keep the production nested lazy-list structure, without loading AppModel or services.
private struct SelectionRows: View {
    @Binding var selection: String?
    @State private var swipe = SwipeState()
    private static let meetings = (0..<30).map { index in
        MeetingListItem(Meeting(id: "fixture-\(index)", title: "Synthetic meeting \(index)",
                                audioName: "synthetic.wav", language: "en", speakerCount: nil, duration: 60))
    }
    var body: some View {
        ScrollView {
            LazyVStack {
                ForEach([0], id: \.self) { _ in
                    ForEach(Array(Self.meetings.enumerated()), id: \.element.id) { _, meeting in
                        SwipeableMeetingRow(meeting: meeting, group: .today,
                                            selection: $selection, swipe: swipe,
                                            open: { selection = meeting.id }, settle: { _ in }, star: {}, delete: {})
                    }
                }
            }
        }.frame(width: 300)
    }
}

@main struct SelectionPreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 520, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Stillnote Selection Preview"
        window.contentView = NSHostingView(rootView: SelectionFixture())
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()
        app.run()
    }
}
