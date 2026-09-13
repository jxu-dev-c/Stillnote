import StillnoteCore
import SwiftUI

struct ContextTab: View {
    @Environment(AppModel.self) private var model
    let meeting: Meeting
    @Binding var notesDirty: Bool

    @State private var draft = NotesDraft()
    @State private var editingLink: ContextLink?
    @State private var addingLink = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            links
            notesSection
        }
        .font(StillnoteTheme.detailBodyFont)
        .onAppear(perform: loadNotes)
        .onDisappear {
            saveTask?.cancel()
            Task { await saveNotes() }
        }
        .sheet(isPresented: $addingLink) { LinkEditor(meeting: meeting, existing: nil) }
        .sheet(item: $editingLink) { link in LinkEditor(meeting: meeting, existing: link) }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Links").font(StillnoteTheme.detailHeadingFont)
                Spacer()
                Button {
                    addingLink = true
                } label: {
                    Label("Add Link", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(meeting.contextLinks.count >= Validation.maxContextLinks)
            }
            if meeting.contextLinks.isEmpty {
                Text("No links yet").foregroundStyle(.secondary)
            } else {
                ForEach(meeting.contextLinks) { link in
                    linkRow(link)
                }
            }
        }
        .contentPanel()
    }

    private func linkRow(_ link: ContextLink) -> some View {
        let url = URL(string: link.url)
        let host = url?.host()?.replacingOccurrences(of: "www.", with: "") ?? link.url
        return HStack(spacing: 10) {
            favicon(for: url)
            VStack(alignment: .leading, spacing: 4) {
                Text(link.title.isEmpty ? host : link.title).lineLimit(1)
                Text(host + (url?.path() ?? "")).font(StillnoteTheme.detailSupportingFont).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let url {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
                    .help("Open in browser")
            }
            Button { editingLink = link } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
            Button(role: .destructive) {
                Task {
                    await model.edit(meeting.id) { $0.contextLinks.removeAll { $0.url == link.url } }
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(.background.tertiary, in: .rect(cornerRadius: 10))
    }

    /// Icons load directly from each website with no referrer and no third-party
    /// icon service; a globe stands in when one is unavailable or the Mac is offline.
    private func favicon(for url: URL?) -> some View {
        let iconURL = url.flatMap { source -> URL? in
            guard let scheme = source.scheme, let host = source.host() else { return nil }
            return URL(string: "\(scheme)://\(host)/favicon.ico")
        }
        return AsyncImage(url: iconURL) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "globe").foregroundStyle(.secondary)
        }
        .frame(width: 24, height: 24)
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notes").font(StillnoteTheme.detailHeadingFont)
                Spacer()
                Text(draft.error != nil ? "Not saved" : (notesDirty ? "Saving…" : "Saved"))
                    .font(StillnoteTheme.detailSupportingFont).foregroundStyle(.secondary)
            }
            if let error = draft.error {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(StillnoteTheme.detailSupportingFont).foregroundStyle(.orange)
                    Button("Retry") { Task { await saveNotes() } }
                }
            }
            TextEditor(text: $draft.text)
                .font(StillnoteTheme.detailBodyFont)
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 200)
                .background(.background, in: .rect(cornerRadius: 10))
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
                .accessibilityLabel("Meeting notes")
                .onChange(of: draft.text) { scheduleSave() }
        }
        .contentPanel()
    }

    // MARK: - Notes drafting

    private func loadNotes() {
        draft.load(meetingID: meeting.id, savedText: meeting.notes)
        notesDirty = draft.isDirty
    }

    private func scheduleSave() {
        saveTask?.cancel()
        draft.recordEdit()
        notesDirty = draft.isDirty
        guard notesDirty else { return }
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await saveNotes()
        }
    }

    private func saveNotes() async {
        await draft.save { pending in
            await model.edit(meeting.id) { $0.notes = pending } != nil
        }
        notesDirty = draft.isDirty
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
