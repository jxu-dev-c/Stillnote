import Observation
import StillnoteCore
import SwiftUI

/// The window's undo toasts, and the deletions they can still take back.
///
/// Deletion is persisted in Recently Deleted; the toast offers a quick restore.
@MainActor
@Observable
final class Feedback {
    struct Toast: Identifiable {
        let id = UUID()
        let text: String
        let undo: (() -> Void)?
    }

    private(set) var toast: Toast?
    /// Meetings deleted from the list whose deletion has not been carried out yet.
    private(set) var pendingDeletes: Set<String> = []
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    static let duration: Duration = .seconds(5)

    func show(_ text: String, undo: (() -> Void)? = nil) {
        dismissal?.cancel()
        let toast = Toast(text: text, undo: undo)
        self.toast = toast
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled, let self, self.toast?.id == toast.id else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.toast = nil }
        }
    }

    func undo() {
        guard let toast else { return }
        dismissal?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { self.toast = nil }
        toast.undo?()
    }

    func dismiss() {
        dismissal?.cancel()
        toast = nil
    }

    /// Hide while the archive write completes, then offer a quick restore.
    func delete(_ meeting: MeetingListItem, model: AppModel) {
        guard !meeting.status.isBusy else {
            model.alertMessage = "This meeting is processing. Wait for it to finish."
            return
        }
        let id = meeting.id
        guard pendingDeletes.insert(id).inserted else { return }
        Task {
            await model.delete(id)
            pendingDeletes.remove(id)
            guard model.recentlyDeleted.contains(where: { $0.id == id }) else { return }
            show("Moved “\(meeting.title)” to Recently Deleted") {
                Task { await model.restoreDeleted(id) }
            }
        }
    }

}

/// The design's toast: a confirmation with an optional Undo, floating at the top of the content.
struct ToastView: View {
    let toast: Feedback.Toast
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Icon(.checkCircle, size: 17, lineWidth: 2)
                .foregroundStyle(DS.Accent.green.ink)
            Text(toast.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.text)
                .lineLimit(1)
            if toast.undo != nil {
                Button(action: undo) {
                    Text("Undo")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.accentInk)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(DS.hover, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, toast.undo == nil ? 14 : 5)
        .frame(height: 40)
        .designMenu(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

extension View {
    /// Shows the window's toast `top` points below this view's top edge, centered.
    func toastOverlay(_ feedback: Feedback, top: CGFloat) -> some View {
        overlay(alignment: .top) {
            if let toast = feedback.toast {
                ToastView(toast: toast, undo: feedback.undo)
                    .padding(.top, top)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.snappy(duration: 0.25), value: feedback.toast?.id)
    }
}
