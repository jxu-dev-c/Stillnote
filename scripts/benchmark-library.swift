// Compiled by benchmark-library.sh against the Release Core objects.
import Darwin
import Foundation
import StillnoteCore

@main struct LibraryBenchmark {
    static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.attoseconds) / 1e15 + Double(elapsed.seconds) * 1000
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    static func main() async throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[2])
        let paths = Paths(dataDirectory: root, modelDirectory: root.appendingPathComponent("models"))
        let opening = ContinuousClock.now
        let store = try Store(paths: paths)
        if args[1] == "prepare" {
            try await store.migrateNamedSpeakers()
            try await store.prepareLibrarySearch()
            print("Migration/index preparation: \(milliseconds(opening)) ms; resident \(residentMB()) MiB")
            return
        }
        if args[1] == "seed" {
            let count = Int(args[3])!
            for i in 0..<count {
                var meeting = Meeting(id: "meeting-\(i)", title: "Planning \(i)", audioName: "synthetic.wav", language: "en", speakerCount: nil, duration: 3600)
                meeting.createdAt = String(format: "2026-01-%02dT%02d:%02d:00+00:00", 1 + i % 28, i % 24, i % 60)
                meeting.status = .complete
                meeting.segments = (0..<600).map { j in
                    Segment(id: "\(j)", start: Double(j * 6), end: Double(j * 6 + 6), speaker: "speaker_1",
                            text: "Meeting \(i), item \(j): we reviewed the product rollout schedule, customer feedback, and assigned the follow-up work. 产品计划。")
                }
                meeting.notes = "Synthetic benchmark notes."
                meeting.summary = MeetingSummary(overview: "Product review", keyPoints: ["Schedule reviewed"], decisions: ["Continue rollout"], actionItems: [], provider: "synthetic", model: "none", generatedAt: meeting.createdAt)
                try await store.insert(meeting)
            }
            try await store.migrateNamedSpeakers()
            print("Seeded \(count) synthetic meetings")
            return
        }
        let baseline = args[1] == "baseline"
        var meetings: [Meeting] = []
        var items: [MeetingListItem] = []
        let start = ContinuousClock.now
        if baseline {
            // Exact pre-change recovery scan, followed by its second full load.
            for meeting in try await store.list() where meeting.status.isBusy {
                try await store.update(meeting.id) { $0.status = .error }
            }
            try await store.migrateNamedSpeakers()
            meetings = try await store.list()
        } else {
            try await store.markInterruptedJobs()
            try await store.migrateNamedSpeakers()
            try await store.prepareLibrarySearch()
            items = try await store.libraryItems()
        }
        let startupMS = milliseconds(start)
        let resident = residentMB()
        let count = baseline ? meetings.count : items.count
        let reader = try Store(paths: paths, readOnly: true)
        var searchMS: [Double] = []
        var hits = 0
        for query in ["rollout", "产品计划", "not-present-in-this-library"] {
            let start = ContinuousClock.now
            if baseline {
                func filter() -> [Meeting] {
                    meetings.filter { ([$0.title] + $0.segments.map(\.text)).joined(separator: " ").lowercased().contains(query) }
                }
                let first = filter()
                hits += first.count
                if !first.isEmpty { hits += filter().count }
            } else {
                hits += try await reader.searchLibrary(query).count
            }
            searchMS.append(milliseconds(start))
        }
        let detailStart = ContinuousClock.now
        let detail = try await store.snapshot(baseline ? meetings[0].id : items[0].id)
        let detailMS = milliseconds(detailStart)
        let updates = (0..<100).map { MeetingListItem(detail.meeting, revision: detail.item.revision + Int64($0 + 1), searchRevision: detail.item.searchRevision) }
        let updateStart = ContinuousClock.now
        for i in 0..<100 {
            if baseline {
                var meeting = meetings[0]
                meeting.progress = Double(i)
                if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index] = meeting }
                meetings.sort { $0.createdAt > $1.createdAt }
            } else {
                MeetingLibrary.apply(updates[i], to: &items)
            }
        }
        let updatesMS = milliseconds(updateStart)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = ["mode": args[1], "count": count, "load_ms": startupMS,
            "resident_after_load_mb": resident, "peak_rss_mb": Double(usage.ru_maxrss) / 1_048_576,
            "search_ms": searchMS, "detail_ms": detailMS, "updates_100_ms": updatesMS, "hits": hits]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
