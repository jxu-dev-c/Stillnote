import StillnoteCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: RootSheet?
    @State private var selection: String?
    @State private var search = ""

    private static let libraryID = "all-meetings"

    private var sidebarSelection: Binding<String?> {
        Binding(
            get: { selection ?? Self.libraryID },
            set: { selection = $0 == Self.libraryID ? nil : $0 }
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
                    sidebar
                } detail: {
                    if let selection, let meeting = model.meeting(selection) {
                        MeetingDetailView(meeting: meeting, selection: $selection)
                            .id(meeting.id)
                    } else {
                        MeetingListView(selection: $selection, search: $search, sheet: $sheet)
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { sheet = .record } label: {
                            Label("New Recording", systemImage: "record.circle")
                        }
                        .help("New Recording (⌘R)")
                        Button { sheet = .importAudio } label: {
                            Label("Import Audio", systemImage: "square.and.arrow.down")
                        }
                        .help("Import Audio (⌘O)")
                    }
                }
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

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                NavigationLink(value: Self.libraryID) {
                    Label("All Meetings", systemImage: "rectangle.stack")
                        .font(StillnoteTheme.detailBodyFont)
                        .badge(Text(model.meetings.count.formatted()).font(StillnoteTheme.detailSupportingFont))
                }
            } header: {
                Text("Library").font(StillnoteTheme.detailSupportingFont.weight(.semibold))
            }

            Section {
                ForEach(model.meetings) { meeting in
                    NavigationLink(value: meeting.id) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meeting.title).font(StillnoteTheme.detailBodyFont.weight(.medium)).lineLimit(1)
                                Text(meeting.createdDate, format: .dateTime.month(.abbreviated).day())
                                    .font(StillnoteTheme.detailSupportingFont)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        } icon: {
                            if meeting.status.isBusy {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: meeting.status == .error ? "exclamationmark.triangle" : "waveform")
                                    .font(StillnoteTheme.detailBodyFont)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Delete…", role: .destructive) {
                            Task { await model.delete(meeting.id) }
                        }
                    }
                }
            } header: {
                Text("Recent Meetings").font(StillnoteTheme.detailSupportingFont.weight(.semibold))
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        .safeAreaInset(edge: .bottom) {
            if !model.speech.ready {
                SetupNotice()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .font(StillnoteTheme.detailSupportingFont)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .buttonStyle(.plain)
                .help("Open Settings")
            }
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
            HStack(spacing: 8) {
                if model.speech.installing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.down.circle")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.speech.installing ? "Downloading speech model" : "Set up transcription")
                        .font(StillnoteTheme.detailBodyFont.weight(.medium))
                    Text(model.speech.detail)
                        .font(StillnoteTheme.detailSupportingFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contentPanel(padding: 12)
    }
}
