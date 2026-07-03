import Foundation
import CoreAudio

extension Notification.Name {
    static let volumeDidChange = Notification.Name("com.volcon.volumeDidChange")
}

class VolumeExecutor {
    static let shared = VolumeExecutor()
    
    enum VolumeDirection {
        case up
        case down
        case mute
    }
    
    func executeVolumeChange(direction: VolumeDirection, for fingerprint: HardwareFingerprint) {
        // 1. Resolve the physical sub-device for this fingerprint
        guard let targetDeviceID = AudioStateManager.shared.resolveDevice(for: fingerprint) else {
            return
        }
        print("VolCon: executeVolumeChange — direction=\(direction) targetDevice=\(targetDeviceID)")

        // 2. Discover channels that actually support volume changes
        let channels = getChannelsWithVolumeSupport(for: targetDeviceID)
        print("VolCon: Channels with volume support on \(targetDeviceID): \(channels)")
        guard !channels.isEmpty else {
            print("VolCon: Device \(targetDeviceID) does not support software volume control.")
            return
        }
        
        let step: Float32 = 0.04 // ~1/25th of volume bar per keypress
        var finalVolume: Float32 = 0
        var anyChannelSet = false

        // 3. Apply new volume to all supported channels
        for channel in channels {
            if applyVolume(to: targetDeviceID, channel: channel, direction: direction, step: step, result: &finalVolume) {
                anyChannelSet = true
            }
        }

        // Master (channel 0) can report as settable yet reject the set with 'nope'
        // (common on aggregate sub-devices). Fall back to the L/R channels.
        if !anyChannelSet && channels == [kAudioObjectPropertyElementMain] {
            print("VolCon: master-channel set failed — falling back to L/R channels")
            for channel: AudioObjectPropertyElement in [1, 2] {
                if applyVolume(to: targetDeviceID, channel: channel, direction: direction, step: step, result: &finalVolume) {
                    anyChannelSet = true
                }
            }
        }

        guard anyChannelSet else {
            print("VolCon: no channel accepted the volume set on \(targetDeviceID)")
            return
        }

        NotificationCenter.default.post(name: .volumeDidChange, object: nil, userInfo: ["volume": finalVolume])
    }

    // Reads, steps, and writes the volume for one channel. Returns true only if the
    // set actually succeeded (status noErr), so callers can detect 'nope' rejections.
    private func applyVolume(to deviceID: AudioDeviceID,
                             channel: AudioObjectPropertyElement,
                             direction: VolumeDirection,
                             step: Float32,
                             result finalVolume: inout Float32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )

        var size = UInt32(MemoryLayout<Float32>.size)
        var currentVolume: Float32 = 0.0
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &currentVolume) == noErr else {
            return false
        }

        var newVolume = currentVolume
        if direction == .up {
            newVolume = min(1.0, currentVolume + step)
        } else if direction == .down {
            newVolume = max(0.0, currentVolume - step)
        }

        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &newVolume)
        if status != noErr {
            print("VolCon: set VolumeScalar failed on device \(deviceID) channel \(channel): \(status)")
            return false
        }
        finalVolume = newVolume
        return true
    }
    
    private func getChannelsWithVolumeSupport(for deviceID: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var channels = [AudioObjectPropertyElement]()
        
        // First try the Master Channel (0)
        if hasVolumeSupport(for: deviceID, channel: kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain] // If master works, no need to touch individual channels
        }
        
        // Fall back to Left (1) and Right (2) channels for stereo devices
        if hasVolumeSupport(for: deviceID, channel: 1) { channels.append(1) }
        if hasVolumeSupport(for: deviceID, channel: 2) { channels.append(2) }
        
        return channels
    }
    
    private func hasVolumeSupport(for deviceID: AudioDeviceID, channel: AudioObjectPropertyElement) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
        var isSettable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        return status == noErr && isSettable.boolValue
    }
}
