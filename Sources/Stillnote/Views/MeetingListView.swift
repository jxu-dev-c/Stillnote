import StillnoteCore
import SwiftUI

struct MeetingListView: View {
    @Environment(AppModel.self) private var model
    let destination: SidebarDestination
    @Binding var selection: String?
    @Binding var search: String
    @Binding var sheet: RootSheet?

    private struct SearchRequest: Equatable {
        var query: String
        var revision: Int
    }

    @State private var matchingIDs = Set<String>()
    @State private var completedRequest: SearchRequest?
    @State private var searchError: String?

    private var request: SearchRequest {
        SearchRequest(query: MeetingLibrary.normalizedQuery(search), revision: model.meetingSearchRevision)
    }

    private var isSearching: Bool {
        !request.query.isEmpty && completedRequest != request
    }

    private var filtered: [MeetingListItem] {
        model.meetings.filter {
            destination.includes($0) && (request.query.isEmpty || matchingIDs.contains($0.id))
        }
    }

    private var title: String {
        switch destination {
        case .all: "All Meetings"
        case .today: "Today"
        case .starred: "Starred"
        case .calendar: "Calendar"
        case .category(let id): model.category(id)?.name ?? "All Meetings"
        }
    }

    /// Shown when a destination other than All Meetings has nothing in it yet.
    @ViewBuilder
    private var emptyDestination: some View {
        switch destination {
        case .today:
            ContentUnavailableView(
                "No meetings today", systemImage: "clock",
                description: Text("Meetings recorded today appear here.")
            )
        case .starred:
            ContentUnavailableView(
                "No starred meetings", systemImage: "star",
                description: Text("Star a meeting from its context menu to keep it here.")
            )
        default:
            ContentUnavailableView(
                "No meetings in \(title)", systemImage: "folder",
                description: Text("Add a meeting to this category from its context menu.")
            )
        }
    }

    private func updateSearch(_ requested: SearchRequest) async {
        searchError = nil
        guard !requested.query.isEmpty else {
            matchingIDs = []
            completedRequest = requested
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(200))
            let matches = try await model.searchMeetings(requested.query)
            try Task.checkCancellation()
            guard request == requested else { return }
            matchingIDs = matches
            completedRequest = requested
        } catch is CancellationError {
            // A newer query, content change, or navigation owns the next result.
        } catch {
            guard request == requested else { return }
            searchError = error.localizedDescription
            completedRequest = requested
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
            } else if isSearching {
                ProgressView("Searching meetings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let searchError {
                ContentUnavailableView {
                    Label("Could not search meetings", systemImage: "exclamationmark.triangle")
                } description: { Text(searchError) } actions: {
                    Button("Try Again") {
                        completedRequest = nil
                        Task { await updateSearch(request) }
                    }
                }
            } else if destination != .calendar && filtered.isEmpty {
                if request.query.isEmpty {
                    emptyDestination
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else if destination == .calendar {
                MeetingCalendarView(meetings: filtered, selection: $selection) { id in
                    Task { await model.delete(id) }
                }
            } else {
                table
            }
        }
        .task(id: request) { await updateSearch(request) }
        .font(StillnoteTheme.detailBodyFont)
        .navigationTitle(title)
        .searchable(text: $search, placement: .toolbar, prompt: "Search meetings")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let count = destination == .calendar ? model.meetings.count : model.meetings.count(where: destination.includes)
        return "\(count) \(count == 1 ? "meeting" : "meetings")"
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
                        HStack(spacing: 6) {
                            Text(meeting.title).fontWeight(.medium).lineLimit(1)
                            if meeting.starred {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                                    .accessibilityLabel("Starred")
                            }
                        }
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
                if let meeting = model.libraryItem(id) {
                    Divider()
                    MeetingOrganizeItems(meeting: meeting)
                    Divider()
                }
                Button("Delete…", role: .destructive) { Task { await model.delete(id) } }
            }
        } primaryAction: { ids in
            selection = ids.first
        }
    }
}
