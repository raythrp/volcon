import Foundation
import CoreAudio

class AudioStateManager {
    static let shared = AudioStateManager()

    private var internalCachedSubDevices: [AudioDeviceID] = []
    private let queue = DispatchQueue(label: "com.volcon.audiostate", attributes: .concurrent)
    private var observedVolumeDeviceID: AudioDeviceID = 0

    var cachedSubDevices: [AudioDeviceID] {
        get { queue.sync { internalCachedSubDevices } }
        set { queue.async(flags: .barrier) { self.internalCachedSubDevices = newValue } }
    }

    init() {
        updateActiveDevice()
        setupListeners()
    }

    // Returns the AudioDeviceID that should receive the volume change for the given fingerprint.
    // In multi-output mode, matches the fingerprint to a specific sub-device.
    // Falls back to the first sub-device if no match is found.
    func resolveDevice(for fingerprint: HardwareFingerprint) -> AudioDeviceID? {
        let devices = cachedSubDevices
        guard !devices.isEmpty else {
            print("VolCon: resolveDevice — no cached sub-devices")
            return nil
        }
        guard devices.count > 1 else { return devices.first }

        print("VolCon: resolveDevice — fingerprint: \(fingerprint)")
        for deviceID in devices {
            let uid = getDeviceUID(deviceID) ?? "<no uid>"
            print("  Checking sub-device \(deviceID) uid='\(uid)'")
            if fingerprint.matches(uid: uid) {
                print("  → Matched!")
                // The IDs in ActiveSubDeviceList can be the aggregate's proxy sub-device
                // objects, which reject VolumeScalar sets ('nope'). Translate the UID to the
                // real hardware AudioDeviceID and control that instead.
                return realDevice(forUID: uid) ?? deviceID
            }
        }

        // For built-in keyboard (fallback fingerprint), find sub-device with built-in transport type.
        // Needed because macOS built-in speaker UIDs (e.g. "AppleHDAEngineOutput:1B,0,1,1:0")
        // don't contain "BuiltIn", so string matching above fails.
        if fingerprint.isBuiltIn {
            for deviceID in devices {
                if getTransportType(deviceID) == kAudioDeviceTransportTypeBuiltIn {
                    print("VolCon: resolveDevice — matched built-in transport → \(deviceID)")
                    return deviceID
                }
            }
        }

        print("VolCon: No fingerprint match — falling back to first sub-device \(devices[0])")
        return devices.first
    }

    private func getTransportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transportType)
        return transportType
    }

    // Translates a device UID string to its real hardware AudioDeviceID via the
    // system object. Returns nil if unknown. Used to bypass aggregate proxy
    // sub-device objects that reject direct VolumeScalar sets.
    func realDevice(forUID uid: String) -> AudioDeviceID? {
        var cfUID = uid as CFString
        var deviceID: AudioDeviceID = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)

        // The translation struct holds raw pointers into cfUID/deviceID; keep both alive
        // for the whole call via nested withUnsafeMutablePointer.
        let status = withUnsafeMutablePointer(to: &cfUID) { inPtr in
            withUnsafeMutablePointer(to: &deviceID) { outPtr -> OSStatus in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(inPtr),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(outPtr),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                  &address, 0, nil, &size, &translation)
            }
        }
        guard status == noErr, deviceID != 0 else { return nil }
        print("VolCon: realDevice — '\(uid)' → \(deviceID)")
        return deviceID
    }

    func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid as String
    }

    // Forces an immediate re-read of the active device and its sub-devices.
    // Needed after in-place aggregate membership edits: changing an already-default
    // aggregate's sub-device list does not fire the default-output listener, so the
    // cache would otherwise stay stale and misroute volume keys.
    func refresh() {
        updateActiveDevice()
    }

    private func updateActiveDevice() {
        var defaultOutputID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &defaultOutputID)
        guard status == noErr, defaultOutputID != 0 else {
            cachedSubDevices = []
            return
        }

        printDeviceInfo(deviceID: defaultOutputID)

        // Use FullSubDeviceList query success as the aggregate detection signal (per AGENTS.md).
        // Then read actual AudioDeviceIDs from ActiveSubDeviceList — FullSubDeviceList returns
        // a CFArray of CFString UIDs, not a raw AudioDeviceID array.
        if let subDevices = fetchPhysicalSubDevices(of: defaultOutputID), !subDevices.isEmpty {
            cachedSubDevices = subDevices
            print("VolCon: Multi-Output device. Sub-device IDs: \(subDevices)")
            for id in subDevices {
                let uid = getDeviceUID(id) ?? "<no uid>"
                print("  Sub-device \(id) UID: \(uid)")
            }
        } else {
            cachedSubDevices = [defaultOutputID]
            print("VolCon: Standard physical device selected: \(defaultOutputID)")
        }

        addVolumeChangeListener(for: defaultOutputID)
    }

    // Listens to CoreAudio volume changes on the default output device and posts
    // .volumeDidChange — this covers Bluetooth headset buttons (AVRCP-handled by macOS,
    // never seen by HIDMonitor) and any path where VolumeExecutor returns early.
    private func addVolumeChangeListener(for deviceID: AudioDeviceID) {
        observedVolumeDeviceID = deviceID
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main) { [weak self] _, _ in
                guard let self = self, deviceID == self.observedVolumeDeviceID else { return }
                self.postCurrentVolume(for: deviceID)
            }
        }
    }

    private func postCurrentVolume(for deviceID: AudioDeviceID) {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume) == noErr {
                NotificationCenter.default.post(name: .volumeDidChange, object: nil, userInfo: ["volume": volume])
                return
            }
        }
    }

    private func printDeviceInfo(deviceID: AudioDeviceID) {
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var deviceName: CFString = "" as CFString
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &deviceName) == noErr {
            print("VolCon: Active Device Name: \(deviceName)")
        }

        var classID: AudioClassID = 0
        var classSize = UInt32(MemoryLayout<AudioClassID>.size)
        var classAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(deviceID, &classAddress, 0, nil, &classSize, &classID) == noErr {
            let bytes = [
                UInt8((classID >> 24) & 0xFF),
                UInt8((classID >> 16) & 0xFF),
                UInt8((classID >> 8) & 0xFF),
                UInt8(classID & 0xFF)
            ]
            let str = String(bytes: bytes, encoding: .ascii) ?? "????"
            print("VolCon: Active Device Class: \(str)")
        }
    }

    // Returns sub-device IDs for an aggregate/multi-output device, or nil if not aggregate.
    // Detection: query FullSubDeviceList (reliable per AGENTS.md).
    // ID extraction: query ActiveSubDeviceList (returns raw AudioDeviceID array, not CFArray).
    private func fetchPhysicalSubDevices(of aggregateID: AudioDeviceID) -> [AudioDeviceID]? {
        var detectAddress = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var detectSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &detectAddress, 0, nil, &detectSize) == noErr else {
            return nil
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var subDevices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &subDevices) == noErr else {
            return nil
        }

        return subDevices.filter { $0 != 0 }
    }

    private func setupListeners() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil) { [weak self] _, _ in
            self?.updateActiveDevice()
        }
    }
}
