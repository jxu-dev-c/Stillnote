import Foundation
import Testing
@testable import StillnoteCore

struct CalendarDurationTests {
    @Test func displaysExplicitUnits() {
        #expect(Formatting.calendarDuration(0) == "0 sec")
        #expect(Formatting.calendarDuration(-1) == "0 sec")
        #expect(Formatting.calendarDuration(.nan) == "0 sec")
        #expect(Formatting.calendarDuration(.infinity) == "0 sec")
        #expect(Formatting.calendarDuration(0.5) == "1 sec")
        #expect(Formatting.calendarDuration(45) == "45 sec")
        #expect(Formatting.calendarDuration(60) == "1 min")
        #expect(Formatting.calendarDuration(1200) == "20 min")
        #expect(Formatting.calendarDuration(3600) == "1 hr")
        #expect(Formatting.calendarDuration(5400) == "1 hr 30 min")
    }

    @Test(arguments: [true, false])
    func ignoresRetiredVideoPreference(_ enabled: Bool) throws {
        let meeting = Meeting(id: "legacy-video", title: "Synthetic", audioName: "a.wav",
                              language: "en", speakerCount: nil, duration: 60, videoName: "v.mp4")
        var document = try JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as! [String: Any]
        document["summary_include_video_path"] = enabled
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: document))
        #expect(decoded.hasVideo)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as! [String: Any]
        #expect(saved["summary_include_video_path"] == nil)
    }
}
