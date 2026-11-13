import StillnoteCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: RootSheet?
    @State private var selection: String?
    @State private var feedback = Feedback()
    @State private var columns: NavigationSplitViewVisibility = .all
    @SceneStorage("sidebarDestination") private var storedDestination: SidebarDestination = .all

    /// The stored destination, or All Meetings when it names a category that was deleted.
    private var destination: Binding<SidebarDestination> {
        Binding(
            get: {
                if case .category(let id) = storedDestination, model.category(id) == nil { return .all }
                return storedDestination
            },
            set: { storedDestination = $0 }
        )
    }

    var body: some View {
        Group {
            if !model.isReady {
                // The window is shown before any filesystem work, so macOS can present
                // its folder-access prompt if this copy needs one.
                starting
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    SidebarView(destination: destination, selection: $selection)
                } detail: {
                    library
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .ignoresSafeArea(.container, edges: .top)
                }
                .navigationSplitViewStyle(.balanced)
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
        }
        .background { WindowBackdrop().ignoresSafeArea() }
        .environment(feedback)
        .task(id: selection) { await model.loadDetail(selection == RecordingSelection.id ? nil : selection) }
        .onChange(of: model.meetings.count) { _, _ in
            if let selection, selection != RecordingSelection.id, model.libraryItem(selection) == nil {
                self.selection = nil
            }
        }
        // All entry points (menu bar, CLI, reminders, and this window) share the recorder.
        // The window shows a recording wherever it began.
        .onChange(of: model.isReady ? model.recorder.session?.id : nil, initial: true) { _, sessionID in
            if sessionID != nil {
                if sheet == .record { sheet = nil }
                if destination.wrappedValue == .calendar || !destination.wrappedValue.showsRecording {
                    destination.wrappedValue = .all
                }
                selection = RecordingSelection.id
            } else if selection == RecordingSelection.id {
                selection = nil
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .record:
                RecordingSheet(selection: $selection)
            case .importAudio:
                ImportSheet(selection: $selection)
            }
        }
        .alert("Stillnote", isPresented: .constant(model.alertMessage != nil)) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    /// The meeting list and the open meeting, or the calendar in their place.
    @ViewBuilder
    private var library: some View {
        if destination.wrappedValue == .calendar {
            MeetingCalendarView(destination: destination, selection: $selection, sheet: $sheet)
        } else {
            HStack(spacing: 0) {
                // With the sidebar folded, the window's controls sit where the list's title is.
                MeetingListPane(destination: destination.wrappedValue, selection: $selection, sheet: $sheet,
                                showsTitle: columns != .detailOnly)
                Hairline(vertical: true)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection {
            if selection == RecordingSelection.id {
                RecordingPage(selection: $selection)
            } else if let meeting = model.meeting(selection) {
                MeetingDetailView(meeting: meeting, selection: $selection)
                    .id(meeting.id)
            } else if let error = model.detailError {
                DetailMessage(title: "Could not load meeting", detail: error) {
                    Button("Try Again") { Task { await model.loadDetail(selection) } }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            DetailMessage(
                title: model.meetings.isEmpty ? "Record your first meeting" : "No meeting selected",
                detail: model.meetings.isEmpty
                    ? "Choose New Meeting to start recording, or import a recording with ⌘O."
                    : "Choose a meeting from the list to read its summary and transcript."
            ) { EmptyView() }
            .toastOverlay(feedback, top: 84)
        }
    }

    @ViewBuilder
    private var starting: some View {
        if let error = model.startupError {
            ContentUnavailableView {
                Label("Stillnote could not open its library", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        } else {
            ProgressView(model.startupStage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension SidebarDestination {
    /// The destinations whose list includes today's meetings, and so the recording.
    var showsRecording: Bool {
        switch self {
        case .all, .today, .calendar: true
        default: false
        }
    }
}

/// A centered title and explanation for an empty or failed detail.
private struct DetailMessage<Actions: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.text)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(DS.text2)
                .multilineTextAlignment(.center)
            actions.padding(.top, 8)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A quiet reminder that transcription needs a one-time local setup.
struct SetupNotice: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if model.speech.installing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.down.circle").font(.system(size: 15))
                    }
                }
                .foregroundStyle(SidebarStyle.accent)
                .frame(width: SidebarStyle.iconSize, height: 17)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.speech.installing ? "Downloading speech model" : "Set up transcription")
                        .font(SidebarStyle.labelFont.weight(.semibold))
                        .foregroundStyle(SidebarStyle.text)
                    Text(model.speech.detail)
                        .font(SidebarStyle.countFont)
                        .foregroundStyle(SidebarStyle.text2)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SidebarStyle.field, in: .rect(cornerRadius: SidebarStyle.rowRadius))
            .contentShape(.rect(cornerRadius: SidebarStyle.rowRadius))
        }
        .buttonStyle(.plain)
    }
}
