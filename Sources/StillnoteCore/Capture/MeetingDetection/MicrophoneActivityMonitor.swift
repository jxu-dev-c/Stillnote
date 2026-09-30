import CoreAudio
import Foundation

/// Reports which meeting apps are capturing from an input device, using Core Audio's process
/// objects. Only process metadata is read: no audio is touched and no permission is needed. The
/// app's own process is excluded, so a Stillnote recording never counts as a meeting app.
///
/// Core Audio does not notify when a process's `IsRunningInput` changes, so the monitor listens
/// for what it does announce — a device starting or stopping anywhere, and processes or devices
/// coming and going — and rereads the process list then, plus once shortly after, since a
/// process's input flag can trail its device starting. Nothing is polled while audio is idle.
public final class MicrophoneActivityMonitor: @unchecked Sendable {
    // Every mutable property below is confined to `queue`, which is also where Core Audio calls
    // the listeners.
    private let queue = DispatchQueue(label: "local.stillnote.microphone-activity")
    private var continuation: AsyncStream<Set<MeetingApp>>.Continuation?
    private var generation = 0
    private var systemListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var last: Set<MeetingApp>?
    private let ownPID = getpid()

    static let settleRereadDelay: DispatchTimeInterval = .milliseconds(750)

    public init() {}

    /// Starts observing, replacing any earlier stream. The current state is delivered first.
    public func start() -> AsyncStream<Set<MeetingApp>> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Set<MeetingApp>.self, bufferingPolicy: .bufferingNewest(1)
        )
        let generation = queue.sync {
            teardown()
            self.generation += 1
            self.continuation = continuation
            for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices] {
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
                var address = Self.address(selector)
                if AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
                ) == noErr {
                    systemListeners.append((selector, listener))
                }
            }
            watchDevices()
            publish()
            return self.generation
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.queue.async { if self.generation == generation { self.teardown() } }
        }
        return stream
    }

    public func stop() {
        queue.sync { teardown() }
    }

    private func teardown() {
        for (selector, listener) in systemListeners {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
        systemListeners = []
        for (device, listener) in deviceListeners {
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
        }
        deviceListeners = [:]
        last = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.finish()
    }

    private func changed() {
        guard continuation != nil else { return }
        watchDevices()
        publish()
        let generation = generation
        queue.asyncAfter(deadline: .now() + Self.settleRereadDelay) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.publish()
        }
    }

    /// Listens on every device for it starting or stopping, following devices as they come and go.
    private func watchDevices() {
        let devices = Set(Self.objects(kAudioHardwarePropertyDevices))
        for (device, listener) in deviceListeners where !devices.contains(device) {
            // The device has gone; removing may fail along with its object, which is harmless.
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, listener)
            deviceListeners[device] = nil
        }
        for device in devices where deviceListeners[device] == nil {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
            var address = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            if AudioObjectAddPropertyListenerBlock(device, &address, queue, listener) == noErr {
                deviceListeners[device] = listener
            }
        }
    }

    private func publish() {
        guard let continuation else { return }
        var apps = Set<MeetingApp>()
        for process in Self.objects(kAudioHardwarePropertyProcessObjectList) {
            guard Self.uint32(process, kAudioProcessPropertyIsRunningInput) == 1,
                  Self.pid(process) != ownPID,
                  let bundleID = Self.bundleID(process),
                  let app = MeetingApps.match(bundleID: bundleID)
            else { continue }
            apps.insert(app)
        }
        guard apps != last else { return }
        last = apps
        continuation.yield(apps)
    }

    // MARK: - Core Audio properties

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
    }

    /// A list of object ids held by the system object, such as its processes or devices.
    private static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func pid(_ process: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func bundleID(_ process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        let bundleID = value.takeRetainedValue() as String
        return bundleID.isEmpty ? nil : bundleID
    }
}
