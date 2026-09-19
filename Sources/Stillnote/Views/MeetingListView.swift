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
                        .primaryActionStyle()
                        .controlSize(.large)
                    Button("Import Audio") { sheet = .importAudio }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                table
            }
        }
        .font(StillnoteTheme.detailBodyFont)
        .navigationTitle("All Meetings")
        .searchable(text: $search, placement: .toolbar, prompt: "Search meetings")
        .navigationSubtitle("\(model.meetings.count) \(model.meetings.count == 1 ? "meeting" : "meetings")")
    }

    private var table: some View {
        Table(filtered, selection: $selection) {
            TableColumn("Meeting") { meeting in
                HStack(spacing: 12) {
                    Image(systemName: meeting.hasVideo ? "video" : "waveform")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 36, height: 36)
                        .background(.tint.opacity(0.10), in: .rect(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meeting.title).fontWeight(.medium).lineLimit(1)
                        Text(meeting.speakers.isEmpty ? "Recording" : "\(meeting.speakers.count) \(meeting.speakers.count == 1 ? "speaker" : "speakers")")
                            .font(StillnoteTheme.detailSupportingFont)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                .help(meeting.title)
            }
            .width(min: 180, ideal: 320)
            TableColumn("Date") { meeting in
                Text(meeting.createdDate, format: .dateTime.month(.abbreviated).day().year())
                    .foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 140, max: 150)
            TableColumn("Duration") { meeting in
                Text(meeting.duration > 0 ? Formatting.duration(meeting.duration) : "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 80, max: 84)
            TableColumn("Status") { meeting in
                MeetingStatusLabel(status: meeting.status, font: StillnoteTheme.detailSupportingFont.weight(.medium))
            }
            .width(min: 150, ideal: 160, max: 180)
        }
        .alternatingRowBackgrounds(.disabled)
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
