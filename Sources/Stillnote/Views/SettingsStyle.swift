import StillnoteCore
import SwiftUI

// MARK: - Tokens

/// The Settings v2 design's colors, for both appearances. Names follow the design's tokens.
extension DS {
    static let card = Color(light: .rgba(255, 255, 255, 0.74), dark: .rgba(255, 255, 255, 0.055))
    static let cardBorder = Color(light: .rgba(0, 0, 0, 0.06), dark: .rgba(255, 255, 255, 0.08))
    /// A recessed well inside a card (the design's `input`).
    static let well = Color(light: .rgba(0, 0, 0, 0.045), dark: .rgba(0, 0, 0, 0.22))
    static let chip = Color(light: .rgba(0, 0, 0, 0.065), dark: .rgba(255, 255, 255, 0.12))
    static let button = Color(light: .rgba(255, 255, 255), dark: .rgba(255, 255, 255, 0.14))
    static let buttonBorder = Color(light: .rgba(0, 0, 0, 0.1), dark: .rgba(255, 255, 255, 0.1))
    static let buttonOff = Color(light: .rgba(0, 0, 0, 0.06), dark: .rgba(255, 255, 255, 0.08))
    static let settingsHover = Color(light: .rgba(0, 0, 0, 0.05), dark: .rgba(255, 255, 255, 0.08))
    static let track = Color(light: .rgba(0, 0, 0, 0.16), dark: .rgba(255, 255, 255, 0.22))
    static let segment = Color(light: .rgba(0, 0, 0, 0.06), dark: .rgba(0, 0, 0, 0.25))
    static let segmentSelected = Color(light: .rgba(255, 255, 255), dark: .rgba(255, 255, 255, 0.2))
    static let okTint = Color(light: .rgba(52, 199, 89, 0.17), dark: .rgba(48, 209, 88, 0.18))
    static let okInk = Color(light: .rgba(27, 122, 55), dark: .rgba(111, 229, 143))
    static let okRow = Color(light: .rgba(52, 199, 89, 0.07), dark: .rgba(48, 209, 88, 0.07))
    static let awayTint = Color(light: .rgba(255, 149, 0, 0.16), dark: .rgba(255, 159, 10, 0.2))
    static let awayInk = Color(light: .rgba(154, 84, 0), dark: .rgba(255, 184, 77))
    static let awayRow = Color(light: .rgba(255, 149, 0, 0.07), dark: .rgba(255, 159, 10, 0.07))
    /// The tinted square behind a card's leading icon (the design's `a1t` and `a1i`).
    static let iconTint = Color(light: .rgba(0, 122, 255, 0.12), dark: .rgba(10, 132, 255, 0.22))
    static let iconInk = Color(light: .rgba(0, 98, 204), dark: .rgba(108, 182, 255))
    static let hatch = Color(light: .rgba(215, 0, 21, 0.2), dark: .rgba(255, 107, 99, 0.32))
    static let wave = Color(light: .rgba(0, 122, 255), dark: .rgba(90, 176, 255))
    static let waveSilence = Color(light: .rgba(60, 60, 67, 0.5), dark: .rgba(235, 235, 245, 0.5))
    static let peoplePanel = Color(light: .rgba(255, 255, 255, 0.85), dark: .rgba(255, 255, 255, 0.05))
    static let peopleField = Color(light: .rgba(118, 118, 128, 0.12), dark: .rgba(255, 255, 255, 0.07))
    static let peopleInput = Color(light: .rgba(118, 118, 128, 0.1), dark: .rgba(255, 255, 255, 0.075))
    static let peopleSelection = Color(light: .rgba(0, 122, 255, 0.12), dark: .rgba(10, 132, 255, 0.26))
    static let save = Color(light: .rgba(0, 98, 204), dark: .rgba(10, 111, 228))
}

enum SettingsMetrics {
    static let cardRadius: CGFloat = 14
    static let rowFont = Font.system(size: 13.5)
    static let captionFont = Font.system(size: 12)
    static let headingFont = Font.system(size: 13, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
}

extension AppModel {
    /// A binding to one setting that shows each change at once and saves it.
    func setting<Value: Equatable>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.changeSettings { $0[keyPath: keyPath] = value } }
        )
    }
}

// MARK: - Layout

/// A titled group: a small bold heading over its cards.
struct SettingsSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(SettingsMetrics.headingFont)
                    .foregroundStyle(DS.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 12)
                accessory
            }
            content
        }
    }
}

/// A rounded card whose children are rows separated by hairlines. Increased contrast
/// strengthens the outline.
struct SettingsCard<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Hairline() }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.card, in: shape)
        .overlay {
            shape.strokeBorder(contrast == .increased ? Color.secondary : DS.cardBorder,
                               lineWidth: contrast == .increased ? 1 : 0.5)
                .allowsHitTesting(false)
        }
    }
}

/// A card row: a label, an optional caption under it, and a trailing control.
struct SettingsRow<Control: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var control: Control

    init(_ title: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(SettingsMetrics.rowFont).foregroundStyle(DS.text)
                if let caption { SettingsCaption(caption) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// Secondary explanatory text.
struct SettingsCaption: View {
    let text: String
    var color: Color = DS.text2

    init(_ text: String, color: Color = DS.text2) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(SettingsMetrics.captionFont)
            .foregroundStyle(color)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A warning or error line inside a card.
struct SettingsNotice: View {
    let text: String
    var color: Color = DS.awayInk

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(SettingsMetrics.captionFont)
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The 44-point tinted square that leads a card header.
struct SettingsIconTile: View {
    let icon: DesignIcon

    var body: some View {
        Icon(icon, size: 22, lineWidth: 1.8)
            .foregroundStyle(DS.iconInk)
            .frame(width: 44, height: 44)
            .background(DS.iconTint, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Controls

/// The design's secondary button: 28 points tall on a raised fill.
struct SettingsButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(DS.text)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(DS.button, in: shape)
            .overlay { shape.strokeBorder(DS.buttonBorder, lineWidth: 0.5) }
            .shadow(color: scheme == .dark ? .clear : .black.opacity(0.12), radius: 0.75, y: 0.5)
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(shape)
    }
}

/// A borderless text button in the accent ink.
struct SettingsLinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var size: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size))
            .foregroundStyle(DS.accentInk)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .hoverFill(.rect(cornerRadius: 8), color: DS.settingsHover)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
    }
}

extension ButtonStyle where Self == SettingsButtonStyle {
    static var settings: SettingsButtonStyle { SettingsButtonStyle() }
}

extension ButtonStyle where Self == SettingsLinkButtonStyle {
    static var settingsLink: SettingsLinkButtonStyle { SettingsLinkButtonStyle() }
}

/// A switch with its label kept for accessibility.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.accent)
    }
}

/// A − value + control. Each press moves by `step`, snapping to multiples of it.
struct SettingsStepper: View {
    let label: String
    @Binding var value: Int
    let step: Int
    let range: ClosedRange<Int>
    let format: (Int) -> String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 2) {
            stepButton(.minus, "Decrease \(label)", enabled: value > range.lowerBound) { value = lower }
            Text(format(value))
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(DS.text)
                .frame(minWidth: 54)
            stepButton(.plus, "Increase \(label)", enabled: value < range.upperBound) { value = higher }
        }
        .padding(.horizontal, 2)
        .frame(height: 28)
        .background(DS.button, in: shape)
        .overlay { shape.strokeBorder(DS.buttonBorder, lineWidth: 0.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if value < range.upperBound { value = higher }
            case .decrement: if value > range.lowerBound { value = lower }
            @unknown default: break
            }
        }
    }

    private var lower: Int {
        let snapped = value % step == 0 ? value - step : value - value % step
        return max(range.lowerBound, min(snapped, value - 1))
    }

    private var higher: Int {
        min(range.upperBound, value - value % step + step)
    }

    private func stepButton(_ icon: DesignIcon, _ help: String, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(icon, size: 12, lineWidth: 2)
                .foregroundStyle(DS.text)
                .frame(width: 26, height: 24)
                .hoverFill(.rect(cornerRadius: 6), color: DS.settingsHover)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(help)
    }
}

/// A plain text field on the design's button fill, for short values such as a model name.
struct SettingsTextField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var width: CGFloat = 220
    var secure = false
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if secure {
                SecureField(label, text: $text, prompt: Text(prompt))
                    .textContentType(.password)
            } else {
                TextField(label, text: $text, prompt: Text(prompt))
            }
        }
        .textFieldStyle(.plain)
        .labelsHidden()
        .font(.system(size: 13))
        .focused($focused)
        .focusEffectDisabled()
        .padding(.horizontal, 10)
        .frame(width: width, height: 28)
        .background(DS.well, in: shape)
        .overlay {
            shape.strokeBorder(focused ? DS.accent.opacity(0.6) : DS.buttonBorder, lineWidth: focused ? 1.5 : 0.5)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(label)
    }
}

/// A small capsule stating a status, such as Ready.
struct SettingsBadge: View {
    enum Tone { case ok, away }
    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 4) {
            if tone == .ok {
                Icon(.check, size: 11, lineWidth: 2.8)
            } else {
                Image(systemName: "exclamationmark").font(.system(size: 9, weight: .heavy))
            }
            Text(text).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(tone == .ok ? DS.okInk : DS.awayInk)
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 20)
        .background(tone == .ok ? DS.okTint : DS.awayTint, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// A status line on a faint tint: a provider installed, or one still to set up.
struct SettingsStatusRow<Action: View>: View {
    let ok: Bool
    let title: String
    var caption: String?
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if ok {
                    Icon(.checkCircle, size: 15, lineWidth: 2)
                } else {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 13, weight: .semibold))
                }
            }
            .foregroundStyle(ok ? DS.okInk : DS.awayInk)
            .frame(width: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text)
                if let caption { SettingsCaption(caption) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(ok ? DS.okRow : DS.awayRow)
    }
}

/// A person's initial in a circle tinted with their stable accent.
struct PersonAvatar: View {
    let name: String
    let accent: DS.Accent
    var size: CGFloat = 28

    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).first.map(String.init)?.uppercased() ?? "?"))
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(accent.ink)
            .frame(width: size, height: size)
            .background(accent.tint, in: .circle)
            .accessibilityHidden(true)
    }
}
