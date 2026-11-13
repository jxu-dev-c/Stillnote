import AppKit
import SwiftUI

/// One cancellable presentation per toolbar, shared by pointer and keyboard input.
@MainActor @Observable
final class ToolbarHelpState {
    private(set) var active: UUID?
    private var pending: Task<Void, Never>?
    private var requested: UUID?

    func show(_ id: UUID, immediately: Bool) {
        dismiss()
        requested = id
        if immediately {
            active = id
        } else {
            pending = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, self.requested == id else { return }
                self.active = id
            }
        }
    }

    func leave(_ id: UUID) {
        guard requested == id else { return }
        dismiss()
    }

    func dismiss() {
        pending?.cancel()
        pending = nil
        requested = nil
        active = nil
    }
}

private struct ToolbarHelpAnchor {
    let bounds: Anchor<CGRect>
    let title: String
    let detail: String?
}

private struct ToolbarHelpAnchors: PreferenceKey {
    static var defaultValue: [UUID: ToolbarHelpAnchor] = [:]
    static func reduce(value: inout [UUID: ToolbarHelpAnchor], nextValue: () -> [UUID: ToolbarHelpAnchor]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ToolbarHelpTarget: ViewModifier {
    @Environment(ToolbarHelpState.self) private var state
    @State private var id = UUID()
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    let title: String
    let detail: String?
    let activate: (() -> Void)?

    @ViewBuilder private func focusTarget(_ content: Content) -> some View {
        if let activate {
            content.focusable(enabled)
                .onKeyPress(keys: [.space, .return]) { press in
                    guard enabled, press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                    state.dismiss()
                    activate()
                    return .handled
                }
                .focused($focused)
        } else {
            content
        }
    }

    func body(content: Content) -> some View {
        focusTarget(content)
            .accessibilityLabel(title)
            .accessibilityHint(detail ?? "")
            .onHover { inside in
                if inside { state.show(id, immediately: false) }
                else { state.leave(id) }
            }
            .onChange(of: focused) { _, value in
                if value { state.show(id, immediately: true) }
                else { state.leave(id) }
            }
            .anchorPreference(key: ToolbarHelpAnchors.self, value: .bounds) {
                [id: ToolbarHelpAnchor(bounds: $0, title: title, detail: detail)]
            }
            .onDisappear { state.leave(id) }
    }
}

private struct ToolbarHelpHost: ViewModifier {
    @State private var state = ToolbarHelpState()
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .environment(state)
            .overlayPreferenceValue(ToolbarHelpAnchors.self) { anchors in
                GeometryReader { proxy in
                    if let id = state.active, let item = anchors[id] {
                        let rect = proxy[item.bounds]
                        // Fit short titles; reserve wrapping space for explanations.
                        let titleWidth = (item.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width + 32
                        let preferredWidth = item.detail == nil ? ceil(titleWidth) : 280
                        let width = min(280, preferredWidth, max(0, proxy.size.width - 16))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).fontWeight(.semibold)
                            if let detail = item.detail, detail != item.title {
                                Text(detail)
                            }
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(DS.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .frame(width: width, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(DS.menuSolid, in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(contrast == .increased ? DS.text : DS.text3,
                                              lineWidth: contrast == .increased ? 1.5 : 0.5)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                        .offset(x: min(max(8, rect.midX - width / 2), proxy.size.width - width - 8),
                                y: rect.maxY + 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .allowsHitTesting(false)
                .transaction { $0.animation = nil }
            }
            .background(ToolbarHelpEvents(state: state))
            .onDisappear { state.dismiss() }
    }
}

/// Observe dismissal without consuming clicks or changing the native responder/focus chain.
private struct ToolbarHelpEvents: NSViewRepresentable {
    let state: ToolbarHelpState
    func makeNSView(context: Context) -> EventView { EventView(state: state) }
    func updateNSView(_ view: EventView, context: Context) {}
    static func dismantleNSView(_ view: EventView, coordinator: ()) { view.stop() }

    final class EventView: NSView {
        let state: ToolbarHelpState
        var monitor: Any?
        var observer: NSObjectProtocol?
        init(state: ToolbarHelpState) {
            self.state = state
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                if event.type != .keyDown || [53, 36, 49, 48].contains(event.keyCode) {
                    self.state.dismiss()
                }
                return event
            }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.state.dismiss() }
                }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            monitor = nil
            observer = nil
            state.dismiss()
        }
    }
}

extension View {
    func toolbarHelp(_ title: String, detail: String? = nil, activate: (() -> Void)? = nil) -> some View {
        modifier(ToolbarHelpTarget(title: title, detail: detail, activate: activate))
    }

    func toolbarHelpHost() -> some View { modifier(ToolbarHelpHost()) }
}
