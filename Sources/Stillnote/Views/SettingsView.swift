import StillnoteCore
import SwiftUI

/// The Settings window's pages. The first four follow a meeting through its lifecycle.
enum SettingsPage: String, CaseIterable, Identifiable {
    case record, transcribe, speakers, summarize, people, commandLine

    var id: String { rawValue }

    static let lifecycle: [SettingsPage] = [.record, .transcribe, .speakers, .summarize]
    static let more: [SettingsPage] = [.people, .commandLine]

    var title: String {
        switch self {
        case .record: "Record"
        case .transcribe: "Transcribe"
        case .speakers: "Speakers"
        case .summarize: "Summarize"
        case .people: "People"
        case .commandLine: "Command line"
        }
    }

    var icon: DesignIcon {
        switch self {
        case .record: .microphone
        case .transcribe: .waveform
        case .speakers: .voice
        case .summarize: .transcript
        case .people: .people
        case .commandLine: .terminal
        }
    }

    /// The rail tile's gradient, top to bottom.
    var tile: [Color] {
        let stops: (NSColor, NSColor) = switch self {
        case .record: (.rgba(255, 107, 97), .rgba(229, 48, 42))
        case .transcribe: (.rgba(75, 166, 255), .rgba(10, 111, 228))
        case .speakers: (.rgba(201, 129, 238), .rgba(154, 63, 208))
        case .summarize: (.rgba(255, 186, 61), .rgba(240, 136, 0))
        case .people: (.rgba(98, 220, 128), .rgba(39, 173, 74))
        case .commandLine: (.rgba(154, 154, 160), .rgba(92, 92, 97))
        }
        return [Color(nsColor: stops.0), Color(nsColor: stops.1)]
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    static let width: CGFloat = 980
    /// The height below the unified toolbar's inset, making the window 640 points tall in all.
    /// The rail and title draw up into that inset.
    static let height: CGFloat = 574

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            SettingsRail(page: $model.settingsPage)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.settingsPage.title)
                    .font(.system(size: 22, weight: .bold))
                    .letterSpacing(-0.02, size: 22)
                    .foregroundStyle(DS.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 28)
                    .padding(.top, 22)
                    .padding(.bottom, 14)
                page
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: Self.width)
        // An ideal height sizes the window; filling the proposal lets the view reach up under the
        // title bar once the safe area is ignored, rather than leaving that height empty below.
        .frame(minHeight: Self.height, idealHeight: Self.height, maxHeight: .infinity)
        .foregroundStyle(DS.text)
        .ignoresSafeArea(.container, edges: .top)
        .background { WindowBackdrop().ignoresSafeArea() }
        .background { SettingsWindowChrome() }
        .navigationTitle(model.settingsPage.title)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    @ViewBuilder
    private var page: some View {
        switch model.settingsPage {
        case .people:
            // People fills the pane with its own scrolling list rather than scrolling as a page.
            PeopleSettingsPage()
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 24)
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch model.settingsPage {
                    case .record: RecordSettingsPage()
                    case .transcribe: TranscribeSettingsPage()
                    case .speakers: SpeakersSettingsPage()
                    case .summarize: SummarizeSettingsPage()
                    case .commandLine: CommandLineSettingsPage()
                    case .people: EmptyView()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .id(model.settingsPage)
        }
    }
}

/// Gives the Settings window an empty unified toolbar. Without one the window controls sit 8 points
/// from the corner, on the rail's rounded edge; the toolbar's taller title bar insets them 18 points,
/// inside the rail, matching the main window, whose SwiftUI toolbar does the same.
private struct SettingsWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ view: WindowView, context: Context) {}

    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.toolbar == nil else { return }
            let toolbar = NSToolbar(identifier: "settings")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
        }
    }
}

/// The glass rail: window controls at the top, then the pages with their colored tiles.
private struct SettingsRail: View {
    @Binding var page: SettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Room for the window's close, minimize, and zoom buttons.
            Color.clear.frame(height: 48)
            ForEach(SettingsPage.lifecycle) { row($0) }
            Color.clear.frame(height: 12)
            ForEach(SettingsPage.more) { row($0) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .designGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings sections")
    }

    private func row(_ item: SettingsPage) -> some View {
        let selected = page == item
        return Button { page = item } label: {
            HStack(spacing: 9) {
                Icon(item.icon, size: 13, lineWidth: 2.2)
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        LinearGradient(colors: item.tile, startPoint: .top, endPoint: .bottom),
                        in: .rect(cornerRadius: 6, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(.white.opacity(0.4), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Color.white : DS.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(height: 34)
            .background(selected ? DS.selection : .clear, in: .rect(cornerRadius: 10, style: .continuous))
            .hoverFill(.rect(cornerRadius: 10, style: .continuous), color: DS.settingsHover)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
