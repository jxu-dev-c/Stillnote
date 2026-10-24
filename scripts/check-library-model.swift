// Exercises AppModel without opening an application window or using private meeting data.
import Foundation
import SwiftUI
import StillnoteCore

enum StillnoteApp { static let mainWindowID = "main" }

enum RootSheet: String, Identifiable { case record, importAudio; var id: String { rawValue } }

@main struct ModelCheck {
    static func require(_ condition: Bool, line: Int = #line) {
        if !condition { FileHandle.standardError.write(Data("Failed check at line \(line)\n".utf8)) }
        precondition(condition)
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: "/tmp/stillnote-model-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("STILLNOTE_DATA_DIR", root.path, 1)
        setenv("STILLNOTE_MODEL_DIR", root.appendingPathComponent("models").path, 1)
        let paths = Paths(dataDirectory: root, modelDirectory: root.appendingPathComponent("models"))
        let store = try Store(paths: paths)
        for id in ["a", "b"] {
            var m = Meeting(id: id, title: "Meeting \(id)", audioName: "synthetic.wav", language: "en", speakerCount: nil, duration: 60)
            m.segments = [Segment(id: "1", start: 0, end: 1, speaker: "s", text: "Transcript \(id)")]
            try await store.insert(m)
        }
        let model = AppModel()
        await model.load()
        FileHandle.standardError.write(Data("startup: \(model.startupError ?? "ready")\n".utf8))
        require(model.isReady && model.meetings.count == 2)
        require(model.selectedMeeting == nil)
        await model.loadDetail("a")
        require(model.selectedMeeting?.segments.first?.text == "Transcript a")
        let revision = model.meetingSearchRevision
        await model.edit("b") { $0.progress = 42 }
        require(model.meetingSearchRevision == revision)
        require(model.selectedMeeting?.id == "a")
        await model.edit("b") { $0.title = "Renamed" }
        require(model.meetingSearchRevision > revision)
        let matches = try await model.searchMeetings("renamed")
        require(matches == ["b"])
        let request = CLIRequest(command: ["transcript", "set"], positionals: ["b"],
                                 values: ["segment": "1", "text": "Corrected through CLI"])
        let response = try await Task.detached {
            try CommandClient.send(request, to: paths.commandSocketURL.path, timeout: 10)
        }.value
        require(response.code == .ok)
        require(model.selectedMeeting?.id == "a")
        let corrected = try await model.searchMeetings("corrected through cli")
        require(corrected == ["b"])
        let first = Task { @MainActor in await model.loadDetail("a") }
        await Task.yield()
        let last = Task { @MainActor in await model.loadDetail("b") }
        await first.value; await last.value
        require(model.selectedMeeting?.id == "b")
        require(model.selectedMeeting?.title == "Renamed")
        require(model.selectedMeeting?.segments.first?.text == "Corrected through CLI")
        await model.edit("b") { $0.notes = "Live edit" }
        require(model.selectedMeeting?.notes == "Live edit")
        await model.loadDetail(nil)
        require(model.selectedMeeting == nil)
        await model.loadDetail("a")
        await model.delete("a")
        require(model.libraryItem("a") == nil && model.selectedMeeting == nil)
        await model.loadDetail("missing")
        require(model.detailError != nil && model.selectedMeeting == nil)
        await model.shutdown()
        print("PASS: metadata-only load, on-demand detail, background search, CLI edits to unopened meetings, revisions, rapid selection, edit refresh, eviction, deletion and missing detail")
    }
}
