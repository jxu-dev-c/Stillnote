import StillnoteCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: RootSheet?
    @State private var selection: String?
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
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

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Button {
                    sheet = .record
                } label: {
                    Label("New Recording", systemImage: "record.circle")
                }
                Button {
                    sheet = .importAudio
                } label: {
                    Label("Import Audio", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.link)

            Section("Meetings") {
                ForEach(model.meetings) { meeting in
                    NavigationLink(value: meeting.id) {
                        Label {
                            Text(meeting.title).lineLimit(1)
                        } icon: {
                            if meeting.status.isBusy {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: meeting.status == .error ? "exclamationmark.triangle" : "waveform")
                            }
                        }
                    }
                    .contextMenu {
                        Button("Delete…", role: .destructive) {
                            Task { await model.delete(meeting.id) }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        .safeAreaInset(edge: .bottom) {
            if !model.speech.ready {
                SetupNotice()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.speech.installing ? "Downloading speech model" : "Set up transcription")
                        .font(.callout.weight(.medium))
                    Text(model.speech.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}
