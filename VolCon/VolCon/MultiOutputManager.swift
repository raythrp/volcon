import Foundation
import CoreAudio

/// Owns and manages a single stacked aggregate ("Multi-Output") device.
/// Membership is driven by the menu bar: each connected output device (except the
/// built-in speaker) can be toggled in or out of the group. Selecting >=1 device
/// makes the group the system default output; deselecting all destroys it and
/// reverts output to the built-in speaker.
class MultiOutputManager {
    static let shared = MultiOutputManager()

    let groupUID = "com.volcon.multioutput"
    let groupName = "VolCon Output"

    struct OutputDevice {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    // MARK: - Public API

    /// Physical output devices eligible for the group: has output streams, not the
    /// built-in speaker, not an aggregate (incl. our own group).
    func listOutputDevices() -> [OutputDevice] {
        return allDevices().compactMap { deviceID -> OutputDevice? in
            guard hasOutputStreams(deviceID) else { return nil }
            let transport = getTransportType(deviceID)
            guard transport != kAudioDeviceTransportTypeBuiltIn,
                  transport != kAudioDeviceTransportTypeAggregate else { return nil }
            guard let uid = getDeviceUID(deviceID), uid != groupUID else { return nil }
            return OutputDevice(id: deviceID, uid: uid, name: getDeviceName(deviceID) ?? uid)
        }
    }

    /// UIDs currently in the group, or empty if the group does not exist.
    func currentMemberUIDs() -> [String] {
        guard let group = findGroup() else { return [] }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(group, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var list: CFArray? = nil
        guard AudioObjectGetPropertyData(group, &address, 0, nil, &size, &list) == noErr,
              let uids = list as? [String] else { return [] }
        return uids
    }

    /// Toggle entry point. Rebuilds the group to exactly `uids` and makes it the
    /// default output. Empty `uids` destroys the group and reverts to built-in.
    func setMembers(_ uids: [String]) {
        if uids.isEmpty {
            if let group = findGroup() {
                AudioHardwareDestroyAggregateDevice(group)
            }
            if let builtIn = builtInOutputDevice() {
                setDefaultOutput(builtIn)
            }
            AudioStateManager.shared.refresh()
            return
        }

        let group: AudioDeviceID
        if let existing = findGroup() {
            setSubDeviceList(uids, on: existing)
            setMasterSubDevice(uids[0], on: existing)
            group = existing
        } else if let created = createGroup(memberUIDs: uids) {
            group = created
        } else {
            print("VolCon: MultiOutputManager — failed to create group")
            return
        }

        setDefaultOutput(group)

        // In-place sub-device edits on an already-default aggregate don't fire the
        // default-output listener; refresh the cache directly so routing stays correct.
        AudioStateManager.shared.refresh()
    }

    // MARK: - Group lifecycle

    func findGroup() -> AudioDeviceID? {
        return allDevices().first { getDeviceUID($0) == groupUID }
    }

    private func createGroup(memberUIDs: [String]) -> AudioDeviceID? {
        let subDeviceList = memberUIDs.map { [kAudioSubDeviceUIDKey: $0] }
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: groupUID,
            kAudioAggregateDeviceNameKey: groupName,
            kAudioAggregateDeviceIsStackedKey: 1,      // stacked == Multi-Output (not plain aggregate)
            kAudioAggregateDeviceIsPrivateKey: 0,      // persist + visible in Audio MIDI Setup
            kAudioAggregateDeviceSubDeviceListKey: subDeviceList,
            kAudioAggregateDeviceMasterSubDeviceKey: memberUIDs[0]
        ]

        var deviceID: AudioDeviceID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        guard status == noErr, deviceID != 0 else {
            print("VolCon: AudioHardwareCreateAggregateDevice failed: \(status)")
            return nil
        }
        return deviceID
    }

    private func setSubDeviceList(_ uids: [String], on group: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var list = uids as CFArray
        let status = AudioObjectSetPropertyData(group, &address, 0, nil,
                                                UInt32(MemoryLayout<CFArray>.size), &list)
        if status != noErr {
            print("VolCon: set FullSubDeviceList failed: \(status)")
        }
    }

    private func setMasterSubDevice(_ uid: String, on group: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyMainSubDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var master = uid as CFString
        AudioObjectSetPropertyData(group, &address, 0, nil,
                                   UInt32(MemoryLayout<CFString>.size), &master)
    }

    // MARK: - Default output

    private func setDefaultOutput(_ deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = deviceID
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        if status != noErr {
            print("VolCon: setDefaultOutput failed: \(status)")
        }
    }

    private func builtInOutputDevice() -> AudioDeviceID? {
        return allDevices().first {
            hasOutputStreams($0) && getTransportType($0) == kAudioDeviceTransportTypeBuiltIn
        }
    }

    // MARK: - CoreAudio helpers

    private func allDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &devices) == noErr else {
            return []
        }
        return devices.filter { $0 != 0 }
    }

    private func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
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

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr else {
            return nil
        }
        return uid as String
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr else {
            return nil
        }
        return name as String
    }
}
