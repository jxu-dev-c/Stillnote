import AVFoundation
import AppKit
import CoreGraphics
import Foundation

public struct CaptureDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct CaptureDisplay: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let name: String
    public init(id: UInt32, name: String) { self.id = id; self.name = name }
}

public struct CapturePermissions: Sendable {
    public enum Microphone: String, Sendable { case authorized, denied, restricted, notDetermined, unknown }
    public let microphone: Microphone
    public let screenAndSystemAudio: Bool

    public init(microphone: Microphone, screenAndSystemAudio: Bool) {
        self.microphone = microphone
        self.screenAndSystemAudio = screenAndSystemAudio
    }

    public var granted: Bool { microphone == .authorized && screenAndSystemAudio }
}

public struct CaptureCapabilities: Sendable {
    public let available: Bool
    public let reason: String?
    public let microphones: [CaptureDevice]
    public let displays: [CaptureDisplay]
    public let defaultDisplayID: UInt32?

    public init(
        available: Bool, reason: String?, microphones: [CaptureDevice], displays: [CaptureDisplay],
        defaultDisplayID: UInt32?
    ) {
        self.available = available
        self.reason = reason
        self.microphones = microphones
        self.displays = displays
        self.defaultDisplayID = defaultDisplayID
    }
}

/// Device discovery and permission state. Enumeration never opens a capture stream,
/// so it cannot trigger a macOS permission prompt on its own.
public enum CaptureDeviceCatalog {
    public static func microphones() -> [CaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    public static func displays() -> [CaptureDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetActiveDisplayList(32, &ids, &count)
        let screens = NSScreen.screens
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).map { id in
            let screen = screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            let name = screen?.localizedName ?? "Display \(id)"
            return CaptureDisplay(id: id, name: name + (id == main ? " (main)" : ""))
        }
    }

    public static func permissions() -> CapturePermissions {
        let microphone: CapturePermissions.Microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .authorized
        case .denied: microphone = .denied
        case .restricted: microphone = .restricted
        case .notDetermined: microphone = .notDetermined
        @unknown default: microphone = .unknown
        }
        return CapturePermissions(
            microphone: microphone, screenAndSystemAudio: CGPreflightScreenCaptureAccess()
        )
    }

    /// Opens the macOS prompts without starting a recording.
    @discardableResult
    public static func requestPermissions() async -> CapturePermissions {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        _ = CGRequestScreenCaptureAccess()
        return permissions()
    }

    public static func capabilities() -> CaptureCapabilities {
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(
            .init(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        ) else {
            return CaptureCapabilities(
                available: false, reason: "Native capture requires macOS 15 or newer.",
                microphones: [], displays: [], defaultDisplayID: nil
            )
        }
        let displays = displays()
        return CaptureCapabilities(
            available: !displays.isEmpty,
            reason: displays.isEmpty ? "No display was found to attach the capture stream to." : nil,
            microphones: microphones(),
            displays: displays,
            defaultDisplayID: CGMainDisplayID()
        )
    }
}
