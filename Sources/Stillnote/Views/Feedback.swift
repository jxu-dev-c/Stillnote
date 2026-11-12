import Observation
import StillnoteCore
import SwiftUI

/// The window's undo toasts, and the deletions they can still take back.
///
/// Deleting a meeting removes its audio for good, so a deletion is held for as long as its
/// toast offers Undo: the meeting leaves the list at once and is deleted when the toast ends.
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

    /// Hides the meeting now and deletes it once Undo is no longer offered.
    func delete(_ meeting: MeetingListItem, model: AppModel) {
        guard !meeting.status.isBusy else {
            model.alertMessage = "This meeting is processing. Wait for it to finish."
            return
        }
        let id = meeting.id
        withAnimation(.snappy(duration: 0.25)) { _ = pendingDeletes.insert(id) }
        show("Deleted “\(meeting.title)”") { [weak self] in
            withAnimation(.snappy(duration: 0.25)) { _ = self?.pendingDeletes.remove(id) }
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.duration + .milliseconds(200))
            guard let self, self.pendingDeletes.contains(id) else { return }
            await model.delete(id)
            self.pendingDeletes.remove(id)
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
