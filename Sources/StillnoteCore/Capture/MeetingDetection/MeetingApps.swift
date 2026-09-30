import Foundation

/// An app whose use of the microphone suggests a meeting has started.
public struct MeetingApp: Hashable, Sendable, Identifiable {
    /// The app's canonical bundle identifier, which is what a muted app is saved as.
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// The meeting apps and browsers that can prompt a meeting reminder. Audio often runs in a helper
/// process, so a bundle identifier also matches every identifier nested under it
/// (`com.google.Chrome.helper` is Chrome), compared without regard to case because some helpers
/// lowercase their parent's identifier.
public enum MeetingApps {
    private struct Entry {
        let app: MeetingApp
        let identifiers: [String]
    }

    private static func entry(_ id: String, _ name: String, also others: [String] = []) -> Entry {
        Entry(app: MeetingApp(id: id, name: name), identifiers: [id] + others)
    }

    private static let entries: [Entry] = [
        entry("com.microsoft.teams2", "Microsoft Teams"),
        entry("com.microsoft.teams", "Microsoft Teams"),
        entry("us.zoom.xos", "Zoom", also: ["us.zoom.CptHost"]),
        entry("Cisco-Systems.Spark", "Webex", also: ["com.webex.meetingmanager", "com.cisco.webexmeetingsapp"]),
        entry("com.tinyspeck.slackmacgap", "Slack"),
        // FaceTime's calls run their audio in the conferencing daemon.
        entry("com.apple.FaceTime", "FaceTime", also: ["com.apple.avconferenced"]),
        entry("com.hnc.Discord", "Discord"),
        // Browsers, for Google Meet, Teams, and other meetings on the web.
        entry("com.google.Chrome", "Google Chrome"),
        entry("com.microsoft.edgemac", "Microsoft Edge"),
        entry("company.thebrowser.Browser", "Arc"),
        entry("com.brave.Browser", "Brave"),
        entry("com.vivaldi.Vivaldi", "Vivaldi"),
        // Firefox captures from its content processes.
        entry("org.mozilla.firefox", "Firefox", also: ["org.mozilla.plugincontainer"]),
        // Safari captures from WebKit's GPU process, not from Safari itself.
        entry("com.apple.Safari", "Safari", also: ["com.apple.WebKit.GPU"]),
    ]

    public static func match(bundleID: String) -> MeetingApp? {
        let candidate = bundleID.lowercased()
        guard !candidate.isEmpty else { return nil }
        return entries.first { entry in
            entry.identifiers.contains { identifier in
                let identifier = identifier.lowercased()
                return candidate == identifier || candidate.hasPrefix(identifier + ".")
            }
        }?.app
    }

    /// A display name for a saved app identifier, falling back to the identifier itself.
    public static func name(for id: String) -> String {
        entries.first { $0.app.id == id }?.app.name ?? id
    }
}
