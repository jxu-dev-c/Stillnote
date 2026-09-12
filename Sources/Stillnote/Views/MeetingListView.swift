import StillnoteCore
import SwiftUI

struct MeetingListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    @Binding var search: String
    @Binding var sheet: RootSheet?

    private var filtered: [Meeting] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.meetings }
        return model.meetings.filter { meeting in
            let haystack = ([meeting.title] + meeting.segments.map(\.text)).joined(separator: " ").lowercased()
            return haystack.contains(query)
        }
    }

    var body: some View {
        Group {
            if model.meetings.isEmpty {
                ContentUnavailableView {
                    Label("No meetings yet", systemImage: "waveform")
                } description: {
                    Text("Record a meeting or import an existing recording to get started.")
                } actions: {
                    Button("New Recording") { sheet = .record }
                        .buttonStyle(.borderedProminent)
                    Button("Import Audio") { sheet = .importAudio }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                table
            }
        }
        .navigationTitle("All Meetings")
        .searchable(text: $search, placement: .toolbar, prompt: "Search meetings")
        .toolbar {
            ToolbarItemGroup {
                Button { sheet = .record } label: { Label("New Recording", systemImage: "record.circle") }
                Button { sheet = .importAudio } label: {
                    Label("Import Audio", systemImage: "square.and.arrow.down")
                }
            }
        }
    }

    private var table: some View {
        Table(filtered, selection: $selection) {
            TableColumn("Meeting") { meeting in
                HStack(spacing: 8) {
                    if meeting.status.isBusy { ProgressView().controlSize(.mini) }
                    Text(meeting.title).fontWeight(.medium).lineLimit(1)
                }
            }
            TableColumn("Date") { meeting in
                Text(meeting.createdDate, format: .dateTime.month(.abbreviated).day().year())
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 120)
            TableColumn("Duration") { meeting in
                Text(meeting.duration > 0 ? Formatting.duration(meeting.duration) : "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 84)
            TableColumn("Status") { meeting in
                Label(meeting.status.label, systemImage: meeting.status.symbol)
                    .foregroundStyle(meeting.status.tint)
                    .labelStyle(.titleAndIcon)
            }
            .width(min: 120, ideal: 150)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button("Open") { selection = id }
                Button("Delete…", role: .destructive) { Task { await model.delete(id) } }
            }
        } primaryAction: { ids in
            selection = ids.first
        }
    }
}
