// Isolated reproduction using the production MeetingListPane and synthetic metadata.
// Build with preview-meeting-selection.sh, then open the printed app path.
// 1. Click Regroup dates before selecting a meeting, then click Synthetic meeting 1.
//    Its row must become blue/AXSelected and match fixture-1 at right.
// 2. Select meeting 2, regroup again, then select meeting 1. Only meeting 1 stays selected.
// 3. Meetings moved into Previous 7 Days must show a weekday, not a time of day.
// Before the fix, moved rows retain their old selection and date formatting.
import AppKit
import SwiftUI
import StillnoteCore

enum StillnoteApp { static let mainWindowID = "main" }
enum RootSheet: String, Identifiable { case record, importAudio; var id: String { rawValue } }

private struct Repro: View {
    @State private var model = AppModel()
    @State private var feedback = Feedback()
    @State private var selection: String?
    @State private var sheet: RootSheet?
    @State private var revision: Int64 = 0
    @State private var dayShift = false
    private static let now = Calendar.current.startOfDay(for: .now).addingTimeInterval(12 * 3600)
    var body: some View {
        HStack {
            MeetingListPane(destination: .all, selection: $selection, sheet: $sheet)
            VStack {
                Text(selection ?? "No selection")
                Button("Regroup dates") { dayShift.toggle(); refresh() }
            }.frame(width: 260)
        }
        .environment(model).environment(feedback)
        .onAppear { refresh() }
    }
    private func refresh() {
        revision += 1
        let rows = (0..<30).map { index in
            var m = Meeting(id: "fixture-\(index)", title: "Synthetic meeting \(index)", audioName: "synthetic.wav", language: "en", speakerCount: nil, duration: 60)
            let days = (index / 3) + (dayShift ? 1 : 0)
            m.createdAt = Meeting.timestamp(Self.now.addingTimeInterval(Double(-days * 86400 - index * 60)))
            return MeetingListItem(m, revision: m.id == selection ? revision : 0)
        }
        model.seedSelectionPreview(rows)
    }
}
@main struct Preview {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 580, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Stillnote Selection Reproduction"
        window.contentView = NSHostingView(rootView: Repro())
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(); app.run()
    }
}
