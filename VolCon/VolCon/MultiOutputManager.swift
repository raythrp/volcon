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
    /// built-in speaker, not an aggregate (incl. our own group). The aux/headphone
    /// jack ("External Headphones") is also BuiltIn transport but is a distinct,
    /// selectable device — only the speaker itself is excluded.
    func listOutputDevices() -> [OutputDevice] {
        return allDevices().compactMap { deviceID -> OutputDevice? in
            guard hasOutputStreams(deviceID) else { return nil }
            guard getTransportType(deviceID) != kAudioDeviceTransportTypeAggregate else { return nil }
            guard !isBuiltInSpeaker(deviceID) else { return nil }
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

        // Members already in the group before this change — leave their volume alone.
        let previousMembers = findGroup() != nil ? Set(currentMemberUIDs()) : []

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

        // Escape the inherited 0%: a newly joined device may carry the built-in speaker's
        // 0% system volume. Bump only NEWLY added members' OWN scalar to an audible floor —
        // never existing members (avoids jolting their volume), and never any aggregate-level
        // main volume (which macOS would hijack for native cross-device key handling).
        let addedMembers = Set(uids).subtracting(previousMembers)
        ensureMembersAudible(addedMembers)

        // In-place sub-device edits on an already-default aggregate don't fire the
        // default-output listener; refresh the cache directly so routing stays correct.
        AudioStateManager.shared.refresh()
    }

    // Raises a newly joined device's own volume to an audible floor if it's stuck
    // near 0 (inherited from the built-in speaker's 0%). Only touches the passed-in
    // members, so devices already in the group keep their current volume.
    private func ensureMembersAudible(_ addedUIDs: Set<String>) {
        let floor: Float32 = 0.2
        for uid in addedUIDs {
            guard let dev = AudioStateManager.shared.realDevice(forUID: uid) else { continue }
            let current = readDeviceVolume(dev)
            print("VolCon: audible — device \(dev) scalar=\(current ?? -1)")
            if let cur = current, cur < 0.1 {
                setDeviceVolume(dev, floor)
                print("VolCon: audible — raised device \(dev) to \(floor)")
            }
        }
    }

    // Reads a device's true output volume: the max across master (0) and L/R (1,2).
    // A device whose real volume is on L/R can report 0 on the master channel, so
    // reading only master would falsely look silent.
    private func readDeviceVolume(_ deviceID: AudioDeviceID) -> Float32? {
        var found = false
        var maxVol: Float32 = 0
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var vol: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &vol) == noErr {
                found = true
                maxVol = max(maxVol, vol)
            }
        }
        return found ? maxVol : nil
    }

    // Writes a device's output volume across whatever channels are settable
    // (master, else L/R) — mirrors VolumeExecutor's channel handling.
    private func setDeviceVolume(_ deviceID: AudioDeviceID, _ value: Float32) {
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue else {
                continue
            }
            var vol = value
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
            if element == kAudioObjectPropertyElementMain { return } // master covers all channels
        }
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
            hasOutputStreams($0) && isBuiltInSpeaker($0)
        }
    }

    /// The internal speaker specifically. The aux/headphone jack is also BuiltIn
    /// transport, so distinguish by UID/name — macOS names the speaker
    /// "BuiltInSpeakerDevice" / "…Speakers", the jack "External Headphones".
    private func isBuiltInSpeaker(_ deviceID: AudioDeviceID) -> Bool {
        guard getTransportType(deviceID) == kAudioDeviceTransportTypeBuiltIn else { return false }
        let uid = getDeviceUID(deviceID) ?? ""
        let name = getDeviceName(deviceID) ?? ""
        return uid.localizedCaseInsensitiveContains("Speaker")
            || name.localizedCaseInsensitiveContains("Speaker")
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
