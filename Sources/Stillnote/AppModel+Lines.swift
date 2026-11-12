import Foundation
import StillnoteCore

/// Giving one transcript line to a different person, which the transcript's speaker chip offers.
extension AppModel {
    /// What a line's reassignment changed, so Undo can put it back.
    struct LineAssignment {
        let segmentID: String
        let previousSpeaker: String
        let previousName: String?
        let previousProfile: String?
    }

    /// Moves one line to the voice already linked to `profile`, or to a new voice for that
    /// person. A voice left with no lines is removed. Like any transcript correction, this
    /// clears the summary.
    func assignLine(_ segmentID: String, in meetingID: String, to profile: SpeakerProfile) async -> LineAssignment? {
        guard let meeting = self.meeting(meetingID),
              let segment = meeting.segments.first(where: { $0.id == segmentID }) else { return nil }
        let undo = LineAssignment(
            segmentID: segmentID, previousSpeaker: segment.speaker,
            previousName: meeting.speakers[segment.speaker], previousProfile: meeting.speakerProfiles[segment.speaker]
        )
        let updated = await editTranscriptReturning(meetingID) { meeting in
            guard let index = meeting.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            let old = meeting.segments[index].speaker
            let label = meeting.speakerProfiles.first(where: { $0.value == profile.id })?.key
                ?? Self.newSpeakerLabel(in: meeting)
            meeting.speakers[label] = profile.name
            meeting.speakerProfiles[label] = profile.id
            meeting.autoSpeakerProfiles[label] = nil
            meeting.segments[index].speaker = label
            if !meeting.segments.contains(where: { $0.speaker == old }) {
                meeting.speakers[old] = nil
                meeting.speakerProfiles[old] = nil
                meeting.autoSpeakerProfiles[old] = nil
            }
        }
        return updated == nil ? nil : undo
    }

    func undoLineAssignment(_ change: LineAssignment, in meetingID: String) async {
        await editTranscript(meetingID) { meeting in
            guard let index = meeting.segments.firstIndex(where: { $0.id == change.segmentID }) else { return }
            let moved = meeting.segments[index].speaker
            if let name = change.previousName { meeting.speakers[change.previousSpeaker] = name }
            meeting.speakerProfiles[change.previousSpeaker] = change.previousProfile
            meeting.segments[index].speaker = change.previousSpeaker
            if moved != change.previousSpeaker, !meeting.segments.contains(where: { $0.speaker == moved }) {
                meeting.speakers[moved] = nil
                meeting.speakerProfiles[moved] = nil
                meeting.autoSpeakerProfiles[moved] = nil
            }
        }
    }

    /// A speaker label no voice in the meeting uses yet.
    static func newSpeakerLabel(in meeting: Meeting) -> String {
        var number = meeting.speakers.count
        while meeting.speakers["speaker_\(number)"] != nil { number += 1 }
        return "speaker_\(number)"
    }
}
