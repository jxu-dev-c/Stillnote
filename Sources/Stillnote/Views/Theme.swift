import SwiftUI

/// Keep glass in the control layer. Reading surfaces use semantic system fills,
/// leaving macOS responsible for appearance, accent color, and vibrancy.
enum StillnoteTheme {
    static let readingWidth: CGFloat = 920
    static let contentInset: CGFloat = 28
    static let cornerRadius: CGFloat = 16

    static let detailTitleFont: Font = .system(size: 32, weight: .semibold)
    static let detailHeadingFont: Font = .system(size: 19, weight: .semibold)
    static let detailBodyFont: Font = .system(size: 17)
    static let detailSupportingFont: Font = .system(size: 15)
}

extension View {
    @ViewBuilder
    func primaryActionStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    func contentPanel(padding: CGFloat = 16) -> some View {
        modifier(ContentPanel(padding: padding))
    }

    func playbackSurface() -> some View {
        modifier(PlaybackSurface())
    }

    /// Register the floating transport with the system's scroll-edge treatment.
    @ViewBuilder
    func playbackBar<Bar: View>(@ViewBuilder content: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: content)
        }
    }
}

private struct ContentPanel: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.background.secondary, in: .rect(cornerRadius: StillnoteTheme.cornerRadius))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: StillnoteTheme.cornerRadius)
                        .stroke(.secondary, lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct PlaybackSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content
                .background(.background, in: .rect(cornerRadius: 24))
                .overlay {
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(.secondary, lineWidth: 1)
                        .allowsHitTesting(false)
                }
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 24))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: 24))
        }
    }
}
