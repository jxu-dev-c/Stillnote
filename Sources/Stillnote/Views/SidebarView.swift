import AppKit
import StillnoteCore
import SwiftUI

/// What the sidebar shows in the content area. Stored per window as a string.
enum SidebarDestination: Hashable, RawRepresentable {
    case all, today, starred, calendar, recentlyDeleted
    case tag(String)

    /// Tags were called categories when destinations were first stored; the prefix stays so a
    /// window reopens on the tag it last showed.
    private static let tagPrefix = "category:"

    init?(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "today": self = .today
        case "starred": self = .starred
        case "calendar": self = .calendar
        case "recentlyDeleted": self = .recentlyDeleted
        default:
            guard rawValue.hasPrefix(Self.tagPrefix) else { return nil }
            self = .tag(String(rawValue.dropFirst(Self.tagPrefix.count)))
        }
    }

    var rawValue: String {
        switch self {
        case .all: "all"
        case .today: "today"
        case .starred: "starred"
        case .calendar: "calendar"
        case .recentlyDeleted: "recentlyDeleted"
        case .tag(let id): Self.tagPrefix + id
        }
    }

    func includes(_ meeting: MeetingListItem) -> Bool {
        switch self {
        case .all, .calendar: true
        case .recentlyDeleted: false
        case .today: Calendar.current.isDateInToday(meeting.startDate)
        case .starred: meeting.starred
        case .tag(let id): meeting.tagIDs.contains(id)
        }
    }
}

// MARK: - Design tokens

/// The sidebar's colors and metrics, taken from the UI refresh design for both appearances.
enum SidebarStyle {
    static let text = Color(light: .rgba(0, 0, 0, 0.88), dark: .rgba(255, 255, 255, 0.92))
    static let text2 = Color(light: .rgba(60, 60, 67, 0.74), dark: .rgba(235, 235, 245, 0.66))
    static let accent = Color(light: .rgba(0, 122, 255), dark: .rgba(10, 132, 255))
    static let accentInk = Color(light: .rgba(0, 98, 204), dark: .rgba(90, 176, 255))
    static let selection = Color(light: .rgba(0, 0, 0, 0.07), dark: .rgba(255, 255, 255, 0.13))
    static let field = Color(light: .rgba(0, 0, 0, 0.055), dark: .rgba(255, 255, 255, 0.09))
    static let separator = Color(light: .rgba(0, 0, 0, 0.09), dark: .rgba(255, 255, 255, 0.09))
    static let menuBackground = Color(light: .rgba(255, 255, 255, 0.98), dark: .rgba(46, 46, 50, 0.98))
    static let menuBorder = Color(light: .rgba(255, 255, 255, 0.95), dark: .rgba(255, 255, 255, 0.16))
    static let menuRing = Color(light: .rgba(0, 0, 0, 0.1), dark: .rgba(0, 0, 0, 0.5))
    static let menuShadow = Color(light: .rgba(40, 50, 90, 0.22), dark: .rgba(0, 0, 0, 0.5))
    static let menuHighlight = Color(light: .rgba(255, 255, 255, 0), dark: .rgba(255, 255, 255, 0.1))

    static let rowHeight: CGFloat = 34
    static let rowRadius: CGFloat = 12
    static let iconSize: CGFloat = 19
    static let labelFont = Font.system(size: 14)
    static let countFont = Font.system(size: 13)
    static let headerFont = Font.system(size: 12, weight: .semibold)
    static let menuWidth: CGFloat = 208
}

extension NSColor {
    static func rgba(_ red: Int, _ green: Int, _ blue: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: alpha)
    }
}

extension Color {
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension TagColor {
    /// The design's accents for the first four, then the matching system colors.
    var color: Color {
        switch self {
        case .blue: Color(light: .rgba(0, 122, 255), dark: .rgba(10, 132, 255))
        case .purple: Color(light: .rgba(175, 82, 222), dark: .rgba(191, 90, 242))
        case .orange: Color(light: .rgba(255, 149, 0), dark: .rgba(255, 159, 10))
        case .green: Color(light: .rgba(52, 199, 89), dark: .rgba(48, 209, 88))
        case .pink: Color(light: .rgba(255, 45, 85), dark: .rgba(255, 55, 95))
        case .teal: Color(light: .rgba(48, 176, 199), dark: .rgba(64, 200, 224))
        case .yellow: Color(light: .rgba(255, 204, 0), dark: .rgba(255, 214, 10))
        case .red: Color(light: .rgba(255, 59, 48), dark: .rgba(255, 69, 58))
        case .gray: Color(light: .rgba(142, 142, 147), dark: .rgba(152, 152, 157))
        }
    }
}

// MARK: - Icons

/// The design's stroke icons, drawn from their 24-unit SVG paths.
enum SidebarGlyph {
    case allMeetings, today, starred, calendar, settings, newTag, more, check, sparkle

    var isFilled: Bool { self == .more }

    var path: Path {
        Path { p in
            func line(_ points: (CGFloat, CGFloat)...) {
                p.move(to: CGPoint(x: points[0].0, y: points[0].1))
                for point in points.dropFirst() { p.addLine(to: CGPoint(x: point.0, y: point.1)) }
            }
            func polygon(_ points: (CGFloat, CGFloat)...) {
                p.move(to: CGPoint(x: points[0].0, y: points[0].1))
                for point in points.dropFirst() { p.addLine(to: CGPoint(x: point.0, y: point.1)) }
                p.closeSubpath()
            }
            func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
                p.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
                p.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r))
            }
            switch self {
            case .allMeetings:
                rect(4, 5.5, 16, 14, 3)
                line((4, 10), (20, 10)); line((8.5, 3.5), (8.5, 6.5)); line((15.5, 3.5), (15.5, 6.5))
            case .today:
                circle(12, 12, 8)
                line((12, 7.5), (12, 12), (15, 14))
            case .starred:
                polygon((12, 4), (14.4, 9), (19.8, 9.7), (15.8, 13.5), (16.8, 18.9),
                        (12, 16.3), (7.2, 18.9), (8.2, 13.5), (4.2, 9.7), (9.6, 9))
            case .calendar:
                rect(3.5, 4.5, 17, 15, 3)
                line((3.5, 9), (20.5, 9)); line((9.5, 9), (9.5, 19.5))
                line((12.5, 12.5), (17, 12.5)); line((12.5, 15.8), (15.5, 15.8))
            case .settings:
                circle(12, 12, 2.5); circle(12, 12, 6)
                line((12, 3.5), (12, 6)); line((12, 18), (12, 20.5)); line((3.5, 12), (6, 12)); line((18, 12), (20.5, 12))
                line((7.8, 7.8), (6, 6)); line((16.2, 16.2), (18, 18)); line((16.2, 7.8), (18, 6)); line((7.8, 16.2), (6, 18))
            case .newTag:
                circle(12, 12, 8.5)
                line((12, 8.5), (12, 15.5)); line((8.5, 12), (15.5, 12))
            case .more:
                circle(5.5, 12, 1.7); circle(12, 12, 1.7); circle(18.5, 12, 1.7)
            case .check:
                line((5, 12.5), (9.5, 17), (19, 7.5))
            case .sparkle:
                polygon((12, 4), (13.6, 8.4), (18, 10), (13.6, 11.6), (12, 16), (10.4, 11.6), (6, 10), (10.4, 8.4))
                polygon((18.5, 15.5), (19.2, 17.3), (21, 18), (19.2, 18.7), (18.5, 20.5), (17.8, 18.7), (16, 18), (17.8, 17.3))
            }
        }
    }
}

struct GlyphView: View {
    let glyph: SidebarGlyph
    var size: CGFloat = SidebarStyle.iconSize
    var lineWidth: CGFloat = 1.7

    var body: some View {
        Canvas { context, canvas in
            context.scaleBy(x: canvas.width / 24, y: canvas.height / 24)
            if glyph.isFilled {
                context.fill(glyph.path, with: .foreground)
            } else {
                context.stroke(glyph.path, with: .foreground,
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var destination: SidebarDestination
    @Binding var selection: String?
    @AppStorage("categorySort") private var sort: TagSort = .manual

    private enum Naming: Identifiable {
        case new
        case rename(MeetingTag)

        var id: String {
            if case .rename(let tag) = self { return tag.id }
            return "new"
        }
    }

    @State private var naming: Naming?
    @State private var draftName = ""
    @State private var pendingDelete: MeetingTag?
    @State private var menuOpen = false
    @State private var menuMonitor: Any?
    @State private var sidebarMaxX: CGFloat = 0
    @State private var dropTarget: String?
    @State private var confirmingAutoTag = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    library
                    tagsHeader
                    tagList
                }
                .padding(.bottom, 10)
            }
            .scrollIndicators(.automatic)
            footer
        }
        .overlay {
            // Clicking anywhere else in the sidebar closes the menu, as a system menu would.
            if menuOpen {
                Color.clear.contentShape(.rect).onTapGesture { menuOpen = false }
            }
        }
        .overlayPreferenceValue(MenuButtonAnchor.self) { anchor in
            if menuOpen, let anchor {
                GeometryReader { proxy in
                    let button = proxy[anchor]
                    TagMenu(sort: $sort, autoTag: autoTagState, newTag: {
                        menuOpen = false
                        draftName = ""
                        naming = .new
                    }, autoTagAction: {
                        menuOpen = false
                        confirmingAutoTag = true
                    }) { menuOpen = false }
                        .offset(x: button.maxX - SidebarStyle.menuWidth, y: button.maxY + 6)
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.frame(in: .global).maxX, initial: true) { _, maxX in
                    sidebarMaxX = maxX
                }
            }
        }
        .onChange(of: menuOpen) { _, open in open ? installMenuMonitor() : removeMenuMonitor() }
        .onChange(of: destination) { _, _ in menuOpen = false }
        .onDisappear { removeMenuMonitor() }
        .navigationSplitViewColumnWidth(236)
        .alert(namingTitle, isPresented: isNaming) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button(namingAction) { commitName() }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?", isPresented: isDeleting, presenting: pendingDelete
        ) { tag in
            Button("Delete Tag", role: .destructive) {
                Task { await model.deleteTag(tag.id) }
            }
        } message: { tag in
            let count = model.tagCounts[tag.id, default: 0]
            Text(count == 0
                 ? "No meetings carry this tag."
                 : "\(count) \(count == 1 ? "meeting" : "meetings") will lose this tag. The meetings and their other tags are kept.")
        }
        .confirmationDialog(
            autoTagTitle, isPresented: $confirmingAutoTag
        ) {
            Button("Suggest Tags") {
                Task { await model.tagUntaggedMeetings() }
            }
        } message: {
            Text("Each meeting's title and summary, or the opening of its transcript, and your tag names are "
                + "sent to OpenAI (\(model.settings.tagging.model)). Stillnote only adds existing tags; it never removes one.")
        }
    }

    // MARK: Sections

    private var library: some View {
        VStack(spacing: 2) {
            libraryRow(.all, "All Meetings", .allMeetings, count: model.meetings.count, countWeight: .medium)
            libraryRow(.today, "Today", .today, count: model.todayCount)
            libraryRow(.starred, "Starred", .starred, count: model.starredCount)
            libraryRow(.calendar, "Calendar", .calendar, count: nil)
        }
        .padding(.top, 6)
        .padding(.horizontal, 10)
    }

    private var tagsHeader: some View {
        HStack {
            Text("Tags")
                .font(SidebarStyle.headerFont)
                .foregroundStyle(SidebarStyle.text2)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { menuOpen.toggle() } label: {
                GlyphView(glyph: .more, size: 18)
                    .frame(width: 26, height: 26)
                    .background(menuOpen ? SidebarStyle.field : .clear, in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(SidebarStyle.text2)
            .help("Tag options")
            .accessibilityLabel("Tag options")
            .anchorPreference(key: MenuButtonAnchor.self, value: .bounds) { $0 }
        }
        .padding(EdgeInsets(top: 14, leading: 20, bottom: 4, trailing: 12))
    }

    private var tagList: some View {
        let counts = model.tagCounts
        return VStack(spacing: 2) {
            ForEach(MeetingTag.sorted(model.tags, by: sort, counts: counts)) { tag in
                tagRow(tag, count: counts[tag.id, default: 0])
            }
        }
        .padding(.horizontal, 10)
    }

    private var footer: some View {
        VStack(spacing: 2) {
            if !model.speech.ready {
                SetupNotice()
                    .padding(.bottom, 6)
            }
            SidebarRow(title: "Recently Deleted", count: model.recentlyDeleted.count,
                       selected: destination == .recentlyDeleted,
                       action: { choose(.recentlyDeleted) }) {
                Icon(.trash, size: 18).foregroundStyle(SidebarStyle.text2)
            }
            SettingsLink {
                SidebarRowLabel(title: "Settings") {
                    GlyphView(glyph: .settings).foregroundStyle(SidebarStyle.text2)
                }
            }
            .buttonStyle(.plain)
            .help("Open Settings")
        }
        .padding(10)
        .overlay(alignment: .top) {
            Rectangle().fill(SidebarStyle.separator).frame(height: 0.5)
        }
    }

    // MARK: Rows

    private func libraryRow(
        _ item: SidebarDestination, _ title: String, _ glyph: SidebarGlyph,
        count: Int?, countWeight: Font.Weight = .regular
    ) -> some View {
        SidebarRow(
            title: title, count: count, countWeight: countWeight, selected: destination == item,
            action: { choose(item) }
        ) {
            GlyphView(glyph: glyph).foregroundStyle(SidebarStyle.accent)
        }
    }

    private func tagRow(_ tag: MeetingTag, count: Int) -> some View {
        let item = SidebarDestination.tag(tag.id)
        return SidebarRow(
            title: tag.name, count: count, selected: destination == item,
            highlighted: dropTarget == tag.id, action: { choose(item) }
        ) {
            Circle()
                .fill(tag.color.color)
                .frame(width: 10, height: 10)
                .frame(width: SidebarStyle.iconSize, height: SidebarStyle.iconSize)
        }
        .contextMenu {
            Button("Rename…") {
                draftName = tag.name
                naming = .rename(tag)
            }
            Picker("Color", selection: Binding(
                get: { tag.color },
                set: { color in Task { await model.recolorTag(tag.id, color) } }
            )) {
                ForEach(TagColor.allCases) { color in
                    Text(color.label).tag(color)
                }
            }
            .pickerStyle(.menu)
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = tag }
        }
        .modifier(TagReorder(
            enabled: sort == .manual, id: tag.id, dropTarget: $dropTarget,
            isTag: { model.tag($0) != nil },
            move: { dragged in Task { await model.moveTag(dragged, onto: tag.id) } }
        ))
    }

    private var autoTagState: AutoTagMenuState {
        if model.tags.isEmpty { return AutoTagMenuState(reason: "Create a tag first") }
        if model.openAIKeySource == nil { return AutoTagMenuState(reason: "Add an OpenAI API key in Settings → Summaries") }
        if !model.taggingMeetings.isEmpty { return AutoTagMenuState(reason: "Suggesting tags…") }
        if model.untaggedMeetingIDs.isEmpty { return AutoTagMenuState(reason: "Every transcribed meeting has a tag") }
        return AutoTagMenuState(reason: nil)
    }

    private var autoTagTitle: String {
        let count = model.untaggedMeetingIDs.count
        return "Suggest tags for \(count) untagged \(count == 1 ? "meeting" : "meetings")?"
    }

    // MARK: Actions

    private func choose(_ item: SidebarDestination) {
        destination = item
        selection = nil
    }

    /// Escape and clicks outside the sidebar close the menu. Clicks inside it are caught by
    /// the overlay so the click that closes the menu does not also select a row.
    private func installMenuMonitor() {
        removeMenuMonitor()
        menuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                menuOpen = false
                return nil
            }
            if event.locationInWindow.x > sidebarMaxX { menuOpen = false }
            return event
        }
    }

    private func removeMenuMonitor() {
        if let menuMonitor { NSEvent.removeMonitor(menuMonitor) }
        menuMonitor = nil
    }

    private var isNaming: Binding<Bool> {
        Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })
    }

    private var isDeleting: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var namingTitle: String {
        if case .rename = naming { return "Rename Tag" }
        return "New Tag"
    }

    private var namingAction: String {
        if case .rename = naming { return "Rename" }
        return "Create"
    }

    private func commitName() {
        let name = draftName
        switch naming {
        case .new:
            Task {
                if let tag = await model.createTag(name: name) { choose(.tag(tag.id)) }
            }
        case .rename(let tag):
            Task { await model.renameTag(tag.id, to: name) }
        case nil:
            break
        }
        naming = nil
    }
}

private struct MenuButtonAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// An icon, a label, and an optional count, laid out like the design's sidebar rows.
private struct SidebarRowLabel<Icon: View>: View {
    let title: String
    var count: Int?
    var countWeight: Font.Weight = .regular
    var selected = false
    var highlighted = false
    @ViewBuilder let icon: Icon

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: SidebarStyle.iconSize, height: SidebarStyle.iconSize)
            Text(title)
                .font(SidebarStyle.labelFont.weight(selected ? .semibold : .regular))
                .foregroundStyle(SidebarStyle.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let count {
                Text(count.formatted())
                    .font(SidebarStyle.countFont.weight(countWeight))
                    .monospacedDigit()
                    .foregroundStyle(SidebarStyle.text2)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: SidebarStyle.rowHeight)
        .background(
            selected ? SidebarStyle.selection : highlighted ? SidebarStyle.field : .clear,
            in: .rect(cornerRadius: SidebarStyle.rowRadius)
        )
        .contentShape(.rect(cornerRadius: SidebarStyle.rowRadius))
    }
}

private struct SidebarRow<Icon: View>: View {
    let title: String
    let count: Int?
    var countWeight: Font.Weight = .regular
    let selected: Bool
    var highlighted = false
    let action: () -> Void
    @ViewBuilder let icon: Icon

    var body: some View {
        Button(action: action) {
            SidebarRowLabel(
                title: title, count: count, countWeight: countWeight,
                selected: selected, highlighted: highlighted, icon: { icon }
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Drag a tag onto another to reorder them, when the sort is Manual.
private struct TagReorder: ViewModifier {
    let enabled: Bool
    let id: String
    @Binding var dropTarget: String?
    let isTag: (String) -> Bool
    let move: (String) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .draggable(id)
                .dropDestination(for: String.self) { ids, _ in
                    guard let dragged = ids.first, dragged != id, isTag(dragged) else { return false }
                    move(dragged)
                    return true
                } isTargeted: { targeted in
                    if targeted { dropTarget = id } else if dropTarget == id { dropTarget = nil }
                }
        } else {
            content
        }
    }
}

// MARK: - Sort menu

/// Whether Auto-Tag Meetings can run, and why not when it can't.
private struct AutoTagMenuState {
    let reason: String?
}

private struct TagMenu: View {
    @Binding var sort: TagSort
    let autoTag: AutoTagMenuState
    let newTag: () -> Void
    let autoTagAction: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TagMenuItem(title: "New Tag…", action: newTag) {
                GlyphView(glyph: .newTag, size: 16, lineWidth: 1.8).foregroundStyle(SidebarStyle.accent)
            }
            separator
            Text("Sort By")
                .font(SidebarStyle.headerFont)
                .foregroundStyle(SidebarStyle.text2)
                .padding(EdgeInsets(top: 4, leading: 10, bottom: 3, trailing: 10))
            ForEach(TagSort.allCases) { option in
                TagMenuItem(title: option.label, action: {
                    sort = option
                    close()
                }) {
                    if sort == option {
                        GlyphView(glyph: .check, size: 13, lineWidth: 2.6).foregroundStyle(SidebarStyle.text)
                    }
                }
                .accessibilityAddTraits(sort == option ? .isSelected : [])
            }
            separator
            TagMenuItem(title: "Auto-Tag Meetings…", action: autoTagAction) {
                GlyphView(glyph: .sparkle, size: 15, lineWidth: 1.9).foregroundStyle(SidebarStyle.accentInk)
            }
            .disabled(autoTag.reason != nil)
            .opacity(autoTag.reason == nil ? 1 : 0.45)
            .help(autoTag.reason ?? "Ask OpenAI which of your tags fit each untagged meeting")
            .accessibilityHint(autoTag.reason ?? "Suggests tags for untagged meetings with OpenAI")
        }
        .padding(6)
        .frame(width: SidebarStyle.menuWidth, alignment: .leading)
        .background(SidebarStyle.menuBackground, in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(SidebarStyle.menuBorder, lineWidth: 0.5)
        }
        .overlay(alignment: .top) {
            Rectangle().fill(SidebarStyle.menuHighlight).frame(height: 1).padding(.horizontal, 10).padding(.top, 0.5)
        }
        .background {
            RoundedRectangle(cornerRadius: 14).stroke(SidebarStyle.menuRing, lineWidth: 1)
        }
        .shadow(color: SidebarStyle.menuShadow, radius: 25, y: 18)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tag options")
    }

    private var separator: some View {
        Rectangle()
            .fill(SidebarStyle.separator)
            .frame(height: 0.5)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
    }
}

private struct TagMenuItem<Icon: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let icon: Icon
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // A fixed column, so unchecked items keep their indent.
                Color.clear.frame(width: 16, height: 16).overlay { icon }
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(SidebarStyle.text)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(height: 28)
            .background(hovering ? SidebarStyle.field : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Star and tag actions, shared by the meeting table and calendar context menus.
struct MeetingOrganizeItems: View {
    @Environment(AppModel.self) private var model
    let meeting: MeetingListItem

    var body: some View {
        Button(meeting.starred ? "Unstar" : "Star") {
            Task { await model.setStarred(meeting.id, !meeting.starred) }
        }
        Menu("Tags") {
            ForEach(MeetingTag.sorted(model.tags, by: .manual)) { tag in
                Toggle(tag.name, isOn: Binding(
                    get: { meeting.tagIDs.contains(tag.id) },
                    set: { _ in Task { await model.toggleTag(tag.id, on: meeting.id) } }
                ))
            }
            if !model.tags.isEmpty { Divider() }
            Button("Suggest Tags") {
                Task { await model.suggestTags(meeting.id) }
            }
            .disabled(
                model.tags.isEmpty || model.openAIKeySource == nil || meeting.status.isBusy
                    || ![.transcribed, .complete].contains(meeting.status) || model.taggingMeetings.contains(meeting.id)
            )
            Button("Clear Tags") {
                Task { await model.clearTags(meeting.id) }
            }
            .disabled(meeting.tagIDs.isEmpty)
        }
    }
}
