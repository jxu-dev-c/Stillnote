import AppKit
import StillnoteCore
import SwiftUI

/// A small floating reminder at the top right of the screen, under the menu bar. It never takes
/// focus from the call it is reminding about: the panel is non-activating, so clicking it leaves
/// the meeting app frontmost.
@MainActor
final class MeetingReminderPanel {
    enum Choice { case record, dismiss, mute, turnOff }

    private var panel: NSPanel?

    func show(app: MeetingApp, onChoice: @escaping (Choice) -> Void) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: MeetingReminderView(app: app, onChoice: onChoice))
        panel.contentView = host
        let size = host.fittingSize
        let screen = NSScreen.screens.first ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrame(
                NSRect(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 8,
                       width: size.width, height: size.height),
                display: true
            )
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        NSAccessibility.post(
            element: panel, notification: .announcementRequested,
            userInfo: [.announcement: "Stillnote: \(app.name) is using the microphone. Record this meeting?"]
        )
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                // A reminder shown again while fading out stays up.
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = ReminderPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        return panel
    }
}

/// Borderless panels refuse key status by default, which would leave the button's menu inert.
private final class ReminderPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct MeetingReminderView: View {
    let app: MeetingApp
    let onChoice: (MeetingReminderPanel.Choice) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Record this meeting?")
                    .font(.headline)
                Text("\(app.name) is using the microphone")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            Spacer(minLength: 8)
            Menu {
                Button("Not Now") { onChoice(.dismiss) }
                Button("Don’t Remind Me for \(app.name)") { onChoice(.mute) }
                Divider()
                Button("Turn Off Meeting Reminders") { onChoice(.turnOff) }
            } label: {
                Text("Start Recording")
            } primaryAction: {
                onChoice(.record)
            }
            .menuStyle(.button)
            .primaryActionStyle()
            .controlSize(.large)
            .fixedSize()
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting reminder")
    }
}
