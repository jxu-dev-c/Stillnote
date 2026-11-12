import AppKit
import StillnoteCore
import SwiftUI

// MARK: - Tokens

/// The UI refresh design's colors for both appearances. Names follow the design's tokens.
enum DS {
    static let text = Color(light: .rgba(0, 0, 0, 0.88), dark: .rgba(255, 255, 255, 0.92))
    static let text2 = Color(light: .rgba(60, 60, 67, 0.74), dark: .rgba(235, 235, 245, 0.66))
    static let text3 = Color(light: .rgba(60, 60, 67, 0.55), dark: .rgba(235, 235, 245, 0.5))
    static let separator = Color(light: .rgba(0, 0, 0, 0.09), dark: .rgba(255, 255, 255, 0.09))
    static let accent = Color(light: .rgba(0, 122, 255), dark: .rgba(10, 132, 255))
    static let accentInk = Color(light: .rgba(0, 98, 204), dark: .rgba(90, 176, 255))
    /// The solid fill of a selected row or segment.
    static let selection = Color(light: .rgba(10, 104, 216), dark: .rgba(10, 111, 228))
    /// Hover and quiet button fills (the design's `sideSel`).
    static let hover = Color(light: .rgba(0, 0, 0, 0.07), dark: .rgba(255, 255, 255, 0.13))
    static let field = Color(light: .rgba(0, 0, 0, 0.055), dark: .rgba(255, 255, 255, 0.09))
    static let lyricOn = Color(light: .rgba(11, 11, 15), dark: .rgba(255, 255, 255))
    static let lyricOff = Color(light: .rgba(0, 0, 0, 0.3), dark: .rgba(255, 255, 255, 0.4))
    static let playFill = Color(light: .rgba(0, 0, 0, 0.88), dark: .rgba(255, 255, 255, 0.92))
    static let playInk = Color(light: .rgba(255, 255, 255), dark: .rgba(28, 28, 30))
    static let star = Color(light: .rgba(255, 204, 0), dark: .rgba(255, 214, 10))
    static let starInk = Color(nsColor: .rgba(58, 44, 0))
    static let starMark = Color(light: .rgba(217, 154, 0), dark: .rgba(255, 214, 10))
    static let swipeDelete = Color(nsColor: .rgba(215, 0, 21))
    static let danger = Color(light: .rgba(215, 0, 21), dark: .rgba(255, 107, 99))
    static let record = Color(light: .rgba(255, 59, 48), dark: .rgba(255, 69, 58))
    static let recordTint = Color(light: .rgba(255, 59, 48, 0.14), dark: .rgba(255, 69, 58, 0.2))
    /// The translucent fill behind sticky headers and docks (the design's `edge`).
    static let edge = Color(light: .rgba(246, 246, 248, 0.78), dark: .rgba(22, 22, 26, 0.72))
    static let weekend = Color(light: .rgba(0, 0, 0, 0.035), dark: .rgba(255, 255, 255, 0.04))
    static let menuBackground = Color(light: .rgba(255, 255, 255, 0.98), dark: .rgba(46, 46, 50, 0.98))
    static let menuSolid = Color(light: .rgba(255, 255, 255), dark: .rgba(46, 46, 50))
    static let menuBorder = Color(light: .rgba(255, 255, 255, 0.95), dark: .rgba(255, 255, 255, 0.16))
    static let menuCaretBorder = Color(light: .rgba(0, 0, 0, 0.08), dark: .rgba(255, 255, 255, 0.16))
    static let window = Color(light: .rgba(246, 246, 248, 0.8), dark: .rgba(30, 30, 34, 0.82))
    static let windowSolid = Color(light: .rgba(246, 246, 248), dark: .rgba(30, 30, 34))

    /// The four accents meetings, speakers, and events are tinted with.
    enum Accent: Int, CaseIterable {
        case blue, orange, purple, green

        var color: Color {
            switch self {
            case .blue: Color(light: .rgba(0, 122, 255), dark: .rgba(10, 132, 255))
            case .orange: Color(light: .rgba(255, 149, 0), dark: .rgba(255, 159, 10))
            case .purple: Color(light: .rgba(175, 82, 222), dark: .rgba(191, 90, 242))
            case .green: Color(light: .rgba(52, 199, 89), dark: .rgba(48, 209, 88))
            }
        }

        /// Text drawn on the tint.
        var ink: Color {
            switch self {
            case .blue: Color(light: .rgba(0, 98, 204), dark: .rgba(108, 182, 255))
            case .orange: Color(light: .rgba(154, 84, 0), dark: .rgba(255, 184, 77))
            case .purple: Color(light: .rgba(138, 47, 190), dark: .rgba(221, 155, 255))
            case .green: Color(light: .rgba(27, 122, 55), dark: .rgba(111, 229, 143))
            }
        }

        var tint: Color {
            switch self {
            case .blue: Color(light: .rgba(0, 122, 255, 0.13), dark: .rgba(10, 132, 255, 0.24))
            case .orange: Color(light: .rgba(255, 149, 0, 0.17), dark: .rgba(255, 159, 10, 0.2))
            case .purple: Color(light: .rgba(175, 82, 222, 0.14), dark: .rgba(191, 90, 242, 0.24))
            case .green: Color(light: .rgba(52, 199, 89, 0.17), dark: .rgba(48, 209, 88, 0.2))
            }
        }

        /// A stable accent for an identifier: the same person keeps their color across launches.
        static func stable(_ key: String) -> Accent {
            var hash: UInt32 = 5381
            for byte in key.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
            return allCases[Int(hash % UInt32(allCases.count))]
        }
    }
}

extension View {
    /// The design's letter spacing, expressed in em of `size`.
    func letterSpacing(_ em: CGFloat, size: CGFloat) -> some View {
        kerning(em * size)
    }
}

// MARK: - Surfaces

/// The design's floating glass controls: a light translucent fill, hairline border, soft shadow,
/// and a top highlight. With Reduce Transparency the fill is opaque.
private struct DesignGlass<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    let blur: Bool

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .background {
                ZStack {
                    if blur && !reduceTransparency { shape.fill(.ultraThinMaterial) }
                    shape.fill(reduceTransparency
                        ? (dark ? Color(white: 0.24) : Color(white: 0.98))
                        : (dark ? Color.white.opacity(0.11) : Color.white.opacity(0.7)))
                }
            }
            .overlay {
                shape.strokeBorder(dark ? Color.white.opacity(0.17) : Color.white.opacity(0.95), lineWidth: 0.5)
            }
            .overlay {
                if dark {
                    // inset 0 1px 0 rgba(255,255,255,0.15)
                    shape.inset(by: 0.5).stroke(
                        LinearGradient(stops: [.init(color: .white.opacity(0.15), location: 0),
                                               .init(color: .clear, location: 0.08)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                }
            }
            .background {
                if !dark { shape.stroke(Color.black.opacity(0.06), lineWidth: 1) }
            }
            .shadow(color: dark ? .black.opacity(0.22) : Color(nsColor: .rgba(40, 50, 90, 0.12)), radius: 9, y: 4)
    }
}

/// The design's popover and menu surface.
private struct DesignMenuSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let shape: S

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .background(DS.menuBackground, in: shape)
            .overlay { shape.strokeBorder(DS.menuBorder, lineWidth: 0.5) }
            .overlay {
                if dark {
                    shape.inset(by: 0.5).stroke(
                        LinearGradient(stops: [.init(color: .white.opacity(0.1), location: 0),
                                               .init(color: .clear, location: 0.04)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
                }
            }
            .background { shape.stroke(dark ? Color.black.opacity(0.5) : Color.black.opacity(0.1), lineWidth: 1) }
            .shadow(color: dark ? .black.opacity(0.5) : Color(nsColor: .rgba(40, 50, 90, 0.22)), radius: 25, y: 18)
    }
}

extension View {
    func designGlass<S: InsettableShape>(_ shape: S, blur: Bool = false) -> some View {
        modifier(DesignGlass(shape: shape, blur: blur))
    }

    func designGlassCapsule(blur: Bool = false) -> some View {
        designGlass(Capsule(), blur: blur)
    }

    func designMenu<S: InsettableShape>(_ shape: S) -> some View {
        modifier(DesignMenuSurface(shape: shape))
    }

    /// A quiet fill while the pointer is over the view, as the design's `:hover` rules do.
    func hoverFill<S: Shape>(_ shape: S, active: Bool = false, color: Color = DS.hover) -> some View {
        modifier(HoverFill(shape: shape, active: active, color: color))
    }
}

private struct HoverFill<S: Shape>: ViewModifier {
    let shape: S
    let active: Bool
    let color: Color
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background((hovering || active) ? color : .clear, in: shape)
            .contentShape(shape)
            .onHover { hovering = $0 }
    }
}

/// The window's translucent backdrop: the desktop blurred behind the window, under the design's tint.
struct WindowBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if reduceTransparency {
            DS.windowSolid
        } else {
            ZStack {
                BehindWindowBlur()
                DS.window
            }
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Icons

/// The design's icons, drawn from their 24-unit SVG sources.
enum DesignIcon {
    case nameMeeting, autoTag, transcribeAgain, regenerate, trash, transcript, sparkle
    case search, sliders, star, play, pause, back15, forward15, chevronDown, check, close, plus
    case waveform, copy, checkCircle, circle, link, back, previous, next, export, more

    fileprivate enum Part {
        case path(String)
        case rect(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        case circle(CGFloat, CGFloat, CGFloat)
    }

    fileprivate var parts: [Part] {
        switch self {
        case .nameMeeting:
            [.path("M4.5 19.5l.9-3.6L14.6 6.7a1.9 1.9 0 0 1 2.7 0l.1.1a1.9 1.9 0 0 1 0 2.7L8.1 18.6z"),
             .path("M13 8.3l2.7 2.7"), .path("M19.5 3v4M17.5 5h4")]
        case .autoTag:
            [.path("M4.5 19.5l9-9"), .path("M12.2 7.8l4 4"), .path("M18 3v4M16 5h4"),
             .path("M20.5 11.5v3M19 13h3"), .path("M9 3.5v3M7.5 5h3")]
        case .transcribeAgain:
            [.path("M19.2 12a7.2 7.2 0 1 1-2.2-5.2"), .path("M19.4 3.8v3.9h-3.9"),
             .path("M9.5 10.5v3M12 9v6M14.5 10.5v3")]
        case .regenerate:
            [.path("M19.5 12a7.5 7.5 0 0 1-13.2 4.9"), .path("M4.5 12a7.5 7.5 0 0 1 13.2-4.9"),
             .path("M17.8 3.8v3.7h-3.7"), .path("M6.2 20.2v-3.7h3.7")]
        case .trash:
            [.path("M5 7h14M10 4h4M7 7l.8 11a2 2 0 0 0 2 1.8h4.4a2 2 0 0 0 2-1.8L17 7M10 11v5M14 11v5")]
        case .transcript:
            [.path("M5 6.5h14M5 11h14M5 15.5h9")]
        case .sparkle:
            [.path("M12 4l1.6 4.4L18 10l-4.4 1.6L12 16l-1.6-4.4L6 10l4.4-1.6z"),
             .path("M18.5 15.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z")]
        case .search:
            [.circle(11, 11, 6), .path("M15.5 15.5L20 20")]
        case .sliders:
            [.path("M4 8h9M17 8h3M4 16h3M11 16h9"), .circle(15, 8, 2), .circle(9, 16, 2)]
        case .star:
            [.path("M12 4l2.4 5 5.4.7-4 3.8 1 5.4L12 16.3l-4.8 2.6 1-5.4-4-3.8L9.6 9z")]
        case .play:
            [.path("M7 4.8v14.4a1 1 0 0 0 1.5.9l11.4-7.2a1 1 0 0 0 0-1.8L8.5 3.9A1 1 0 0 0 7 4.8z")]
        case .pause:
            [.rect(6, 5, 4.2, 14, 1.4), .rect(13.8, 5, 4.2, 14, 1.4)]
        case .back15:
            [.path("M5.5 9.5A7.5 7.5 0 1 1 4.6 14"), .path("M5.5 5v4.5H10")]
        case .forward15:
            [.path("M18.5 9.5A7.5 7.5 0 1 0 19.4 14"), .path("M18.5 5v4.5H14")]
        case .chevronDown:
            [.path("M6 9.5l6 6 6-6")]
        case .check:
            [.path("M5 12.5l4.5 4.5L19 7.5")]
        case .close:
            [.path("M6 6l12 12M18 6L6 18")]
        case .plus:
            [.path("M12 5v14M5 12h14")]
        case .waveform:
            [.path("M5 10v4M9 7v10M13 4v16M17 8v8M21 11v2")]
        case .copy:
            [.rect(8.5, 8.5, 11, 11, 2.5),
             .path("M15.5 8.5V7A2.5 2.5 0 0 0 13 4.5H7A2.5 2.5 0 0 0 4.5 7v6A2.5 2.5 0 0 0 7 15.5h1.5")]
        case .checkCircle:
            [.circle(12, 12, 8.5), .path("M8.5 12.3l2.4 2.4 4.6-5")]
        case .circle:
            [.circle(12, 12, 8.5)]
        case .link:
            [.path("M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"),
             .path("M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1")]
        case .back:
            [.path("M14.5 5.5L8 12l6.5 6.5")]
        case .previous:
            [.path("M14.5 6L8.5 12l6 6")]
        case .next:
            [.path("M9.5 6l6 6-6 6")]
        case .export:
            [.path("M12 14.5V4M8 7.5l4-3.5 4 3.5"), .path("M8 10.5H7a2.5 2.5 0 0 0-2.5 2.5v4.5A2.5 2.5 0 0 0 7 20h10a2.5 2.5 0 0 0 2.5-2.5V13a2.5 2.5 0 0 0-2.5-2.5h-1")]
        case .more:
            [.circle(5.5, 12, 1.7), .circle(12, 12, 1.7), .circle(18.5, 12, 1.7)]
        }
    }

    var path: Path {
        var result = Path()
        for part in parts {
            switch part {
            case .path(let data): result.addPath(SVGPath.parse(data))
            case .rect(let x, let y, let w, let h, let r):
                result.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r))
            case .circle(let x, let y, let r):
                result.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        }
        return result
    }
}

/// Draws a `DesignIcon` in the current foreground style, stroked like the design's SVGs or filled.
struct Icon: View {
    let icon: DesignIcon
    var size: CGFloat = 20
    var lineWidth: CGFloat = 1.7
    var filled = false

    init(_ icon: DesignIcon, size: CGFloat = 20, lineWidth: CGFloat = 1.7, filled: Bool = false) {
        self.icon = icon
        self.size = size
        self.lineWidth = lineWidth
        self.filled = filled
    }

    var body: some View {
        let path = Self.cache(icon)
        let filled = filled, lineWidth = lineWidth
        return Canvas { context, canvas in
            context.scaleBy(x: canvas.width / 24, y: canvas.height / 24)
            if filled {
                context.fill(path, with: .foreground)
            } else {
                context.stroke(path, with: .foreground,
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if icon == .back15 || icon == .forward15 {
                // <text x="12" y="15.4" font-size="7.6" font-weight="700">15</text>
                Text("15")
                    .font(.system(size: 7.6 * size / 24, weight: .bold))
                    .position(x: size / 2, y: (15.4 - 2.8) * size / 24)
            }
        }
        .accessibilityHidden(true)
    }

    @MainActor private static var paths: [DesignIcon: Path] = [:]

    @MainActor private static func cache(_ icon: DesignIcon) -> Path {
        if let path = paths[icon] { return path }
        let path = icon.path
        paths[icon] = path
        return path
    }
}

/// A minimal SVG path-data reader: M, L, H, V, C, S, A, and Z, absolute and relative.
enum SVGPath {
    static func parse(_ data: String) -> Path {
        var path = Path()
        var scanner = Tokens(Array(data.utf8))
        var current = CGPoint.zero, start = CGPoint.zero, lastControl: CGPoint?
        var command: UInt8 = 0
        while let next = scanner.command(defaultingTo: command) {
            command = next
            let relative = command >= 97
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                current = point(scanner.number(), scanner.number())
                start = current
                path.move(to: current)
                // Further pairs after a move are lines.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
                lastControl = nil
            case UInt8(ascii: "l"):
                current = point(scanner.number(), scanner.number())
                path.addLine(to: current)
                lastControl = nil
            case UInt8(ascii: "h"):
                let x = scanner.number()
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case UInt8(ascii: "v"):
                let y = scanner.number()
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
            case UInt8(ascii: "c"):
                let c1 = point(scanner.number(), scanner.number())
                let c2 = point(scanner.number(), scanner.number())
                let end = point(scanner.number(), scanner.number())
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case UInt8(ascii: "s"):
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = point(scanner.number(), scanner.number())
                let end = point(scanner.number(), scanner.number())
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case UInt8(ascii: "a"):
                let rx = scanner.number(), ry = scanner.number(), rotation = scanner.number()
                let large = scanner.flag(), sweep = scanner.flag()
                let end = point(scanner.number(), scanner.number())
                addArc(&path, from: current, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                current = end
                lastControl = nil
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
                lastControl = nil
            default:
                return path
            }
        }
        return path
    }

    private struct Tokens {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == 32 || bytes[index] == 44 || bytes[index] == 10 { index += 1 }
        }

        /// The next command letter, or the previous command when numbers follow implicitly.
        mutating func command(defaultingTo previous: UInt8) -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            if (65...90).contains(byte) || (97...122).contains(byte) {
                index += 1
                return byte
            }
            return previous == 0 ? nil : previous
        }

        mutating func number() -> CGFloat {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 { index += 1 }
            var seenDot = false, seenExponent = false
            while index < bytes.count {
                let byte = bytes[index]
                if (48...57).contains(byte) {
                    index += 1
                } else if byte == 46, !seenDot, !seenExponent {
                    seenDot = true
                    index += 1
                } else if (byte == 101 || byte == 69), !seenExponent {
                    seenExponent = true
                    index += 1
                    if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 { index += 1 }
                } else {
                    break
                }
            }
            return CGFloat(Double(String(decoding: bytes[begin..<index], as: UTF8.self)) ?? 0)
        }

        mutating func flag() -> Bool {
            skipSeparators()
            guard index < bytes.count else { return false }
            defer { index += 1 }
            return bytes[index] == 49
        }
    }

    /// Endpoint-to-center arc conversion (SVG 1.1, appendix F.6), drawn as cubic segments.
    private static func addArc(
        _ path: inout Path, from p0: CGPoint, to p1: CGPoint,
        rx: CGFloat, ry: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool
    ) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = sqrt(max(0, numerator / denominator))
        if large == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let sign: CGFloat = ux * vy - uy * vx < 0 ? -1 : 1
            let dot = (ux * vx + uy * vy) / (hypot(ux, uy) * hypot(vx, vy))
            return sign * acos(max(-1, min(1, dot)))
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        var theta = theta1
        func pointAt(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi,
                    y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func derivative(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi,
                    y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }
        for _ in 0..<segments {
            let next = theta + step
            let a = pointAt(theta), b = pointAt(next)
            let da = derivative(theta), db = derivative(next)
            path.addCurve(
                to: b,
                control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y)
            )
            theta = next
        }
    }
}

// MARK: - Small parts

/// The design's spinner: a faint ring with a bright quarter arc.
struct RingSpinner: View {
    var size: CGFloat = 15
    var track: Color
    var arc: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turns = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            ZStack {
                Circle().stroke(track, lineWidth: 2 * size / 16).padding(size / 8)
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(arc, style: StrokeStyle(lineWidth: 2 * size / 16, lineCap: .round))
                    .padding(size / 8)
                    .rotationEffect(.degrees(reduceMotion ? 0 : turns * 360 - 90))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A dot that fades between full and 35% opacity every 1.6 seconds, unless motion is reduced.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            let opacity = reduceMotion ? 1 : 0.675 + 0.325 * cos(phase * 2 * .pi)
            Circle().fill(color).frame(width: size, height: size).opacity(opacity)
        }
        .accessibilityHidden(true)
    }
}

/// A hairline rule in the design's separator color.
struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(DS.separator)
            .frame(width: vertical ? 0.5 : nil, height: vertical ? nil : 0.5)
    }
}
