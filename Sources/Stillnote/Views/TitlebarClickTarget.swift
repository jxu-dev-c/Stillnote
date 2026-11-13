import AppKit
import SwiftUI

/// Routes clicks to a content button drawn beneath the transparent native title bar.
/// The SwiftUI button still owns its appearance, keyboard input, and accessibility action.
struct TitlebarClickTarget: NSViewRepresentable {
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> EventView { EventView() }

    func updateNSView(_ view: EventView, context: Context) {
        view.action = action
        view.enabled = enabled
    }

    static func dismantleNSView(_ view: EventView, coordinator: ()) { view.stop() }

    final class EventView: NSView {
        var action: (() -> Void)?
        var enabled = true
        private var monitor: Any?
        private var tracking = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self else { return event }
                return MainActor.assumeIsolated { self.handle(event) }
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.attachedSheet == nil,
                  enabled, !isHiddenOrHasHiddenAncestor else {
                tracking = false
                return event
            }
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            switch event.type {
            case .leftMouseDown:
                tracking = inside
                return inside ? nil : event
            case .leftMouseDragged:
                return tracking ? nil : event
            case .leftMouseUp:
                guard tracking else { return event }
                tracking = false
                if inside { action?() }
                return nil
            default:
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            tracking = false
        }
    }
}
