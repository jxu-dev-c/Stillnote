import StillnoteCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: RootSheet?
    @State private var selection: String?
    @State private var search = ""
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
        @Bindable var model = model
        Group {
            if !model.isReady {
                // The window is shown before any filesystem work, so macOS can present
                // its folder-access prompt if this copy needs one.
                starting
            } else {
                NavigationSplitView {
                    SidebarView(destination: destination, selection: $selection)
                } detail: {
                    if let selection {
                        if let meeting = model.meeting(selection) {
                            MeetingDetailView(meeting: meeting, selection: $selection)
                                .id(meeting.id)
                        } else if let error = model.detailError {
                            ContentUnavailableView {
                                Label("Could not load meeting", systemImage: "exclamationmark.triangle")
                            } description: { Text(error) } actions: {
                                Button("Try Again") { Task { await model.loadDetail(selection) } }
                            }
                        } else {
                            ProgressView("Loading meeting…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        MeetingListView(
                            destination: destination.wrappedValue, selection: $selection,
                            search: $search, sheet: $sheet
                        )
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { sheet = .record } label: {
                            ToolbarIcon("New Recording", systemImage: "record.circle")
                        }
                        .help("New Recording (⌘R)")
                        Button { sheet = .importAudio } label: {
                            ToolbarIcon("Import Audio", systemImage: "arrow.down.circle")
                        }
                        .help("Import Audio (⌘O)")
                    }
                }
            }
        }
        .task(id: selection) { await model.loadDetail(selection) }
        .onChange(of: model.meetings.count) { _, _ in
            if let selection, model.libraryItem(selection) == nil {
                self.selection = nil
            }
        }
        // All entry points (menu bar, CLI, reminders, and this window) share the
        // recorder. Present its session even when it began outside this view.
        .onChange(of: model.isReady ? model.recorder.session?.id : nil, initial: true) { _, sessionID in
            if sessionID != nil {
                sheet = .record
            } else if sheet == .record {
                sheet = nil
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
