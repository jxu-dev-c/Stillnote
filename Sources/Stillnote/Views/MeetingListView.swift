import StillnoteCore
import SwiftUI

enum LibraryTab: String, CaseIterable, Identifiable {
    case list, calendar
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct MeetingListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    @Binding var search: String
    @Binding var sheet: RootSheet?
    // Scene storage survives this view being rebuilt when a meeting is opened and closed.
    @SceneStorage("libraryTab") private var tab: LibraryTab = .list

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
        request.query.isEmpty ? model.meetings : model.meetings.filter { matchingIDs.contains($0.id) }
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
            } else if tab == .list && filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if tab == .calendar {
                MeetingCalendarView(meetings: filtered, selection: $selection) { id in
                    Task { await model.delete(id) }
                }
            } else {
                table
            }
        }
        .task(id: request) { await updateSearch(request) }
        .toolbar {
            if !model.meetings.isEmpty {
                ToolbarItem(placement: .principal) {
                    Picker("Library view", selection: $tab) {
                        ForEach(LibraryTab.allCases) { tab in
                            Text(tab.label).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
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
