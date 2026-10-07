import StillnoteCore
import SwiftUI

struct SummaryTab: View {
    let meeting: Meeting
    let requestSummary: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let summary = meeting.summary {
                if meeting.summaryContextChanged {
                    HStack(spacing: 12) {
                        Label("Notes or links changed since this summary was made.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Regenerate", action: requestSummary)
                            .disabled(meeting.status.isBusy)
                    }
                }
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
