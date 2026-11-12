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

/// Use the symbol's geometric bounds instead of its text baseline in icon-only toolbars.
struct ToolbarIcon: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Image(systemName: systemImage)
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
            .frame(width: 24, height: 24)
            .accessibilityLabel(title)
    }
}
