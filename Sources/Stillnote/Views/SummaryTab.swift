import StillnoteCore
import SwiftUI

struct SummaryTab: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    let requestSummary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            agentRow

            if let summary = meeting.summary {
                sections(summary)
            } else {
                ContentUnavailableView {
                    Label("No summary yet", systemImage: "sparkles")
                } description: {
                    Text("Create an overview, key points, decisions, and action items from this transcript.")
                } actions: {
                    Button("Create Summary", action: requestSummary)
                        .buttonStyle(.borderedProminent)
                        .disabled(meeting.status.isBusy)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var agentRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Summary agent") {
                Text("\(model.settings.summary.provider.label) · \(model.settings.summary.model)")
                    .foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(
                get: { meeting.summaryIncludeVideoPath },
                set: { value in
                    Task { await model.edit(meeting.id) { $0.summaryIncludeVideoPath = value } }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Send video path to AI")
                    Text(meeting.hasVideo
                        ? "Includes the local video path in summary prompts for this recording. "
                            + "This shares the path only; video analysis is not enabled."
                        : "Available for recordings with saved screen video.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!meeting.hasVideo || meeting.status.isBusy)
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    private func sections(_ summary: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Overview").font(.headline)
                Spacer()
                Button(action: requestSummary) {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(meeting.status.isBusy)
            }
            Text(summary.overview).textSelection(.enabled)

            list("Key takeaways", systemImage: "list.bullet", items: summary.keyPoints, empty: "No key points.")
            list("Decisions", systemImage: "checkmark.seal", items: summary.decisions, empty: "No decisions.")

            VStack(alignment: .leading, spacing: 8) {
                Label("Next steps", systemImage: "arrow.right.circle").font(.headline)
                if summary.actionItems.isEmpty {
                    Text("No action items.").foregroundStyle(.secondary)
                } else {
                    ForEach(summary.actionItems) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text).textSelection(.enabled)
                            Text(subtitle(item)).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Text("Generated with \(summary.provider) · \(summary.model)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func list(_ title: String, systemImage: String, items: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage).font(.headline)
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

/// Every provider may send transcript text to a hosted model, so each summary is
/// confirmed separately rather than through a remembered preference.
struct ConsentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(meeting.summaryIncludeVideoPath ? "Send transcript and video path?" : "Send transcript?")
                .font(.headline)
            Text(
                "\(model.settings.summary.provider.label) runs on this Mac but may send the transcript to its "
                    + "model provider."
                    + (meeting.summaryIncludeVideoPath
                        ? " The recording's local video path is included as text; the video file is not sent."
                        : "")
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Form {
                LabeledContent("Provider", value: model.settings.summary.provider.label)
                LabeledContent("Model", value: model.settings.summary.model)
                LabeledContent("Thinking", value: model.settings.summary.reasoningEffort.label)
            }
            .formStyle(.grouped)
            .frame(height: 110)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Send & Summarize") {
                    dismiss()
                    Task { await model.summarize(meeting.id, allowRemote: true) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
