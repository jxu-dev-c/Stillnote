import StillnoteCore
import SwiftUI

struct SummaryTab: View {
    let meeting: Meeting
    let requestSummary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let summary = meeting.summary {
                sections(summary)
            } else {
                ContentUnavailableView {
                    Label("No summary yet", systemImage: "sparkles")
                } description: {
                    Text("Create an overview, key points, decisions, and action items from this transcript.")
                } actions: {
                    Button("Create Summary", action: requestSummary)
                        .primaryActionStyle()
                        .controlSize(.large)
                        .disabled(meeting.status.isBusy)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .font(StillnoteTheme.detailBodyFont)
    }

    private func sections(_ summary: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            SummarySection(title: "Overview", systemImage: "text.alignleft") {
                Text(summary.overview).textSelection(.enabled)
            }

            list("Key takeaways", systemImage: "list.bullet", items: summary.keyPoints, empty: "No key points.")
            list("Decisions", systemImage: "checkmark.seal", items: summary.decisions, empty: "No decisions.")

            SummarySection(title: "Next steps", systemImage: "arrow.right.circle") {
                if summary.actionItems.isEmpty {
                    Text("No action items.").foregroundStyle(.secondary)
                } else {
                    ForEach(summary.actionItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.text).textSelection(.enabled)
                            Text(subtitle(item)).font(StillnoteTheme.detailSupportingFont).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Text("Generated with \(summary.provider) · \(summary.model)")
                .font(StillnoteTheme.detailSupportingFont)
                .foregroundStyle(.secondary)
        }
        .lineSpacing(5)
    }

    private func list(_ title: String, systemImage: String, items: [String], empty: String) -> some View {
        SummarySection(title: title, systemImage: systemImage) {
            if items.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(item).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func subtitle(_ item: ActionItem) -> String {
        var parts = [item.owner ?? "Unassigned"]
        if let due = item.due { parts.append("due \(due)") }
        return parts.joined(separator: " · ")
    }
}

private struct SummarySection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: systemImage)
                .font(StillnoteTheme.detailHeadingFont)
            VStack(alignment: .leading, spacing: 12, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentPanel(padding: 20)
    }
}

/// What a confirmed provider request produces.
enum ProviderRequest: String, Identifiable {
    case summary, title
    var id: String { rawValue }
}

/// Every provider may send meeting text to a hosted model, so each summary and each title
/// suggestion is confirmed separately rather than through a remembered preference.
struct ConsentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    let request: ProviderRequest
    @State private var includeVideoPath: Bool
    @State private var submitting = false

    init(meeting: Meeting, request: ProviderRequest = .summary) {
        self.meeting = meeting
        self.request = request
        _includeVideoPath = State(initialValue: meeting.hasVideo && meeting.summaryIncludeVideoPath)
    }

    /// Naming sends the summary when there is one, and the transcript otherwise.
    private var sent: String {
        request == .title && meeting.summary != nil ? "summary" : "transcript"
    }

    private var note: String {
        if request == .title { return " It suggests a title only; the summary is unchanged." }
        return includeVideoPath
            ? " The recording's local video path is included as text; the video file is not sent."
            : ""
    }

    /// Naming always runs at low effort; see `MeetingNamer`.
    private var effort: ReasoningEffort {
        let summary = model.settings.summary
        return request == .title ? ReasoningEffort.low.supported(by: summary.provider) : summary.resolvedReasoningEffort
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request == .summary && includeVideoPath ? "Send transcript and video path?" : "Send \(sent)?")
                .font(.headline)
            Text(
                "\(model.settings.summary.provider.label) runs on this Mac but may send the \(sent) to its "
                    + "model provider." + note
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                detail("Provider", value: model.settings.summary.provider.label)
                detail("Model", value: model.settings.summary.model)
                detail("Thinking", value: effort.label)
            }
            .contentPanel()

            if request == .summary { videoPathToggle }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(submitting)
                Button(request == .title ? "Send & Name" : "Send & Summarize", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(meeting.status.isBusy || submitting)
            }
        }
        .padding(20)
        .frame(width: 440)
        .interactiveDismissDisabled(submitting)
    }

    private var videoPathToggle: some View {
        Toggle(isOn: $includeVideoPath) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Send video path to AI")
                Text(meeting.hasVideo
                    ? "Includes the local video path in summary prompts for this recording. "
                        + "This shares the path only; video analysis is not enabled."
                    : "Available for recordings with saved screen video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!meeting.hasVideo || meeting.status.isBusy || submitting)
    }

    private func submit() {
        submitting = true
        if request == .title {
            dismiss()
            Task { await model.suggestTitle(meeting.id, allowRemote: true) }
            return
        }
        let sendVideoPath = meeting.hasVideo && includeVideoPath
        Task {
            guard await model.edit(meeting.id, {
                $0.summaryIncludeVideoPath = sendVideoPath
            }) != nil else {
                submitting = false
                return
            }
            dismiss()
            await model.summarize(meeting.id, allowRemote: true)
        }
    }

    private func detail(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
