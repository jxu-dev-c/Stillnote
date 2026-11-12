import AppKit
import StillnoteCore
import SwiftUI

/// The summary, decisions, and action items, then the meeting's links and notes.
struct SummaryPage: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    let summarize: () -> Void
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                overview
                if let summary = meeting.summary {
                    Hairline().padding(.vertical, 28)
                    findings(summary)
                }
                Hairline().padding(.vertical, 28)
                TwoColumns {
                    LinksSection(meeting: meeting)
                } trailing: {
                    NotesSection(meeting: meeting)
                }
            }
            .padding(EdgeInsets(top: 20, leading: 28, bottom: 112, trailing: 28))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .accessibilityLabel("Meeting summary")
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Icon(.sparkle, size: 16, lineWidth: 1.8).foregroundStyle(DS.accentInk)
                Text("Summary")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .help(meeting.summary.map { "Generated with \($0.provider) · \($0.model)" } ?? "")
                Spacer(minLength: 8)
                if let summary = meeting.summary {
                    Button { copy(summary) } label: {
                        HStack(spacing: 6) {
                            Icon(copied ? .check : .copy, size: 15, lineWidth: 1.8)
                            Text(copied ? "Copied" : "Copy").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(DS.text)
                        .padding(.leading, 10)
                        .padding(.trailing, 12)
                        .frame(height: 30)
                        .background(DS.hover, in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .help("Copy summary")
                }
            }
            .frame(minHeight: 28)
            .padding(.bottom, 12)

            if let summary = meeting.summary {
                Text(summary.overview)
                    .font(.system(size: 24, weight: .medium))
                    .letterSpacing(-0.02, size: 24)
                    .lineSpacing(4.5)
                    .foregroundStyle(DS.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: 780, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if meeting.summaryContextChanged {
                    HStack(spacing: 8) {
                        Text("Notes or links changed since this summary was made.")
                            .foregroundStyle(DS.text2)
                        Button("Regenerate", action: summarize)
                            .buttonStyle(.plain)
                            .foregroundStyle(DS.accentInk)
                            .fontWeight(.semibold)
                            .disabled(meeting.status.isBusy)
                    }
                    .font(.system(size: 13))
                    .padding(.top, 12)
                }
            } else {
                Text("No summary yet. \(pendingMessage)")
                    .font(.system(size: 20, weight: .medium))
                    .letterSpacing(-0.015, size: 20)
                    .lineSpacing(4)
                    .foregroundStyle(DS.text2)
                    .frame(maxWidth: 780, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if canSummarize {
                    Button(action: summarize) {
                        Text("Create Summary")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.text)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .designGlassCapsule()
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 18)
                }
            }
        }
    }

    private var canSummarize: Bool {
        !meeting.segments.isEmpty && !meeting.status.isBusy && !model.splittingMeetings.contains(meeting.id)
    }

    private var pendingMessage: String {
        switch meeting.status {
        case .transcribing: return "Waiting for the transcript to finish."
        case .summarizing: return "Writing the summary from the transcript…"
        default:
            return meeting.segments.isEmpty
                ? "A summary is written from the transcript."
                : "Create one from the transcript."
        }
    }

    private func copy(_ summary: MeetingSummary) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Exporter.summaryText(summary), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    // MARK: Decisions and actions

    private func findings(_ summary: MeetingSummary) -> some View {
        TwoColumns {
            VStack(alignment: .leading, spacing: 28) {
                if !summary.keyPoints.isEmpty {
                    SectionBlock(title: "Key points") {
                        ForEach(Array(summary.keyPoints.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(DS.text3).frame(width: 5, height: 5)
                                    .frame(width: 18).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                                Text(point)
                            }
                        }
                    }
                }
                SectionBlock(title: "Decisions") {
                    if summary.decisions.isEmpty {
                        Text("No decisions.").foregroundStyle(DS.text2)
                    }
                    ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, decision in
                        HStack(alignment: .top, spacing: 10) {
                            Icon(.checkCircle, size: 18, lineWidth: 1.8)
                                .foregroundStyle(DS.Accent.green.ink)
                                .padding(.top, 1)
                            Text(decision)
                        }
                    }
                }
            }
        } trailing: {
            SectionBlock(title: "Action items", spacing: 16) {
                if summary.actionItems.isEmpty {
                    Text("No action items.").foregroundStyle(DS.text2)
                }
                ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { index, item in
                    ActionItemRow(item: item) { toggle(index) }
                }
            }
        }
        .font(.system(size: 15))
        .lineSpacing(3)
        .foregroundStyle(DS.text)
        .textSelection(.enabled)
    }

    private func toggle(_ index: Int) {
        Task {
            await model.edit(meeting.id) { meeting in
                guard let items = meeting.summary?.actionItems, items.indices.contains(index) else { return }
                meeting.summary?.actionItems[index].completed = !(items[index].completed ?? false)
            }
        }
    }
}

/// The design's two equal columns with a 48-point gutter.
private struct TwoColumns<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            leading.frame(maxWidth: .infinity, alignment: .topLeading)
            trailing.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct SectionBlock<Content: View, Accessory: View>: View {
    let title: String
    var spacing: CGFloat = 12
    @ViewBuilder let content: Content
    @ViewBuilder let accessory: Accessory

    init(title: String, spacing: CGFloat = 12, @ViewBuilder content: () -> Content,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.spacing = spacing
        self.content = content()
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                accessory
            }
            .frame(minHeight: 28)
            .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: spacing) { content }
        }
    }
}

private struct ActionItemRow: View {
    let item: ActionItem
    let toggle: () -> Void

    var body: some View {
        let done = item.completed ?? false
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                Group {
                    if done {
                        Circle().fill(DS.accent)
                            .overlay { Icon(.check, size: 12, lineWidth: 2.8).foregroundStyle(.white) }
                            .frame(width: 17, height: 17)
                            .frame(width: 20, height: 20)
                    } else {
                        Icon(.circle, size: 20, lineWidth: 1.7).foregroundStyle(DS.text3)
                    }
                }
                .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(item.text) \(done ? "not complete" : "complete")")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .strikethrough(done, color: DS.text3)
                    .foregroundStyle(done ? DS.text2 : DS.text)
                    .lineSpacing(1.5)
                HStack(spacing: 6) {
                    if let owner = item.owner, !owner.isEmpty {
                        let accent = DS.Accent.stable(owner)
                        Text(Meeting.initial(owner))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(accent.ink)
                            .frame(width: 16, height: 16)
                            .background(accent.tint, in: .circle)
                    }
                    Text(meta)
                }
                .font(.system(size: 13))
                .foregroundStyle(DS.text2)
            }
        }
    }

    private var meta: String {
        var parts = [item.owner.flatMap { $0.isEmpty ? nil : $0 } ?? "Unassigned"]
        if let due = item.due, !due.isEmpty { parts.append(due) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Links

private struct LinksSection: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    @State private var adding = false
    @State private var editing: ContextLink?

    var body: some View {
        SectionBlock(title: "Links", spacing: 2) {
            if meeting.contextLinks.isEmpty {
                Text("No links yet. Add any you want to keep with this meeting.")
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(DS.text2)
            }
            ForEach(meeting.contextLinks) { link in
                LinkRow(link: link, edit: { editing = link }, remove: { remove(link) })
            }
        } accessory: {
            Button { adding = true } label: {
                Icon(.plus, size: 16, lineWidth: 2)
                    .foregroundStyle(DS.accentInk)
                    .frame(width: 24, height: 24)
                    .hoverFill(Circle())
            }
            .buttonStyle(.plain)
            .disabled(meeting.contextLinks.count >= Validation.maxContextLinks)
            .help("Add link")
            .accessibilityLabel("Add link")
        }
        .sheet(isPresented: $adding) { LinkEditor(meeting: meeting, existing: nil) }
        .sheet(item: $editing) { link in LinkEditor(meeting: meeting, existing: link) }
    }

    private func remove(_ link: ContextLink) {
        Task { await model.edit(meeting.id) { $0.contextLinks.removeAll { $0.url == link.url } } }
    }
}

private struct LinkRow: View {
    let link: ContextLink
    let edit: () -> Void
    let remove: () -> Void

    var body: some View {
        let url = URL(string: link.url)
        let host = url?.host()?.replacingOccurrences(of: "www.", with: "") ?? link.url
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 12) {
                Icon(.link, size: 16, lineWidth: 1.8)
                    .foregroundStyle(DS.accentInk)
                    .frame(width: 32, height: 32)
                    .background(DS.hover, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 0) {
                    Text(link.title.isEmpty ? host : link.title)
                        .font(.system(size: 15))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                    Text(host)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.text2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .help(link.url)
        .contextMenu {
            Button("Open in Browser") { if let url { NSWorkspace.shared.open(url) } }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url, forType: .string)
            }
            Button("Edit…", action: edit)
            Divider()
            Button("Remove", role: .destructive, action: remove)
        }
    }
}

// MARK: - Notes

private struct NotesSection: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    @State private var draft = NotesDraft()
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        SectionBlock(title: "Notes", spacing: 8) {
            TextEditor(text: $draft.text)
                .font(.system(size: 15))
                .lineSpacing(4.5)
                .foregroundStyle(DS.text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 11)
                .padding(.vertical, 14)
                .frame(height: 112)
                .background(DS.field, in: .rect(cornerRadius: 14))
                .accessibilityLabel("Meeting notes")
                .onChange(of: draft.text) { scheduleSave() }
            if let error = draft.error {
                HStack(spacing: 8) {
                    Text(error).foregroundStyle(.orange)
                    Button("Retry") { Task { await save() } }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.accentInk)
                }
                .font(.system(size: 12.5))
            }
        } accessory: {
            if draft.isDirty && draft.error == nil {
                Text("Saving…").font(.system(size: 12.5)).foregroundStyle(DS.text3)
            }
        }
        .onAppear { draft.load(meetingID: meeting.id, savedText: meeting.notes) }
        .onDisappear {
            saveTask?.cancel()
            Task { await save() }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        draft.recordEdit()
        guard draft.isDirty else { return }
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func save() async {
        await draft.save { pending in
            await model.edit(meeting.id) { $0.notes = pending } != nil
        }
    }
}

struct LinkEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let meeting: Meeting
    let existing: ContextLink?

    @State private var address = ""
    @State private var label = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "Add link" : "Edit link").font(.headline)
            Form {
                TextField("URL", text: $address, prompt: Text("https://example.com"))
                TextField("Label", text: $label, prompt: Text("Use the page title"))
            }
            .formStyle(.grouped)
            .frame(height: 90)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            address = existing?.url ?? ""
            label = existing?.title ?? ""
        }
    }

    private func save() async {
        let others = meeting.contextLinks.filter { $0.url != existing?.url }
        do {
            let url = try Validation.contextLinkURL(address, existing: others)
            saving = true
            var title = label.trimmingCharacters(in: .whitespacesAndNewlines)
            // A blank label borrows the page's own title; a failed lookup never blocks saving.
            if title.isEmpty { title = await LinkMetadata.pageTitle(url) }
            let link = ContextLink(url: url, title: String(title.prefix(Validation.maxLinkTitleLength)))
            await model.edit(meeting.id) { meeting in
                if let existing, let index = meeting.contextLinks.firstIndex(where: { $0.url == existing.url }) {
                    meeting.contextLinks[index] = link
                } else {
                    meeting.contextLinks.append(link)
                }
            }
            dismiss()
        } catch {
            saving = false
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
