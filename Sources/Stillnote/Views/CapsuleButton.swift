import SwiftUI

/// The compact secondary action used by Copy, Listen, and Restore.
/// Call sites supply content and behavior; sizing, colors, and shape stay shared.
struct CapsuleButton: View {
    let title: String
    var icon: DesignIcon?
    var iconFilled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Icon(icon, size: 15, lineWidth: 1.8, filled: iconFilled)
                }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(DS.text)
            .padding(.leading, icon == nil ? 12 : 10)
            .padding(.trailing, 12)
            .frame(height: 30)
            .background(DS.hover, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}
