import Foundation

/// Stored media keeps the Python app's layout — `audio/<meeting-id>` with no
/// extension — but AVFoundation picks its demuxer from the path extension and refuses
/// an extensionless file. Resolving through a symlink keeps both true at once.
public enum MediaFile {
    public static func audioURL(for meeting: Meeting, paths: Paths) -> URL {
        let stored = paths.audioURL(meeting.id)
        let suffix = URL(fileURLWithPath: meeting.audioName).pathExtension.lowercased()
        return link(stored, named: meeting.id, extension: suffix.isEmpty ? "wav" : suffix, paths: paths)
    }

    public static func videoURL(for meeting: Meeting, paths: Paths) -> URL {
        link(paths.videoURL(meeting.id), named: meeting.id + "-video", extension: "mp4", paths: paths)
    }

    private static func link(
        _ stored: URL, named name: String, extension suffix: String, paths: Paths
    ) -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: stored.path) else { return stored }
        let directory = paths.dataDirectory.appendingPathComponent("media", isDirectory: true)
        try? manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let target = directory.appendingPathComponent(name).appendingPathExtension(suffix)
        let existing = try? manager.destinationOfSymbolicLink(atPath: target.path)
        if existing == stored.path { return target }
        try? manager.removeItem(at: target)
        guard (try? manager.createSymbolicLink(at: target, withDestinationURL: stored)) != nil else {
            return stored
        }
        return target
    }

    /// Removes the resolved links for a meeting that is being deleted.
    public static func forget(_ meetingID: String, paths: Paths) {
        let directory = paths.dataDirectory.appendingPathComponent("media", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in contents where name.hasPrefix(meetingID) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
