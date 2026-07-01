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
        
        let step: Float32 = 0.06 // Roughly 1/16th of volume bar
        var finalVolume: Float32 = 0

        // 3. Apply new volume to all supported channels
        for channel in channels {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: channel
            )

            var size: UInt32 = UInt32(MemoryLayout<Float32>.size)
            var currentVolume: Float32 = 0.0

            let status = AudioObjectGetPropertyData(targetDeviceID, &address, 0, nil, &size, &currentVolume)
            guard status == noErr else { continue }

            var newVolume = currentVolume
            if direction == .up {
                newVolume = min(1.0, currentVolume + step)
            } else if direction == .down {
                newVolume = max(0.0, currentVolume - step)
            }

            AudioObjectSetPropertyData(targetDeviceID, &address, 0, nil, size, &newVolume)
            finalVolume = newVolume
        }

        NotificationCenter.default.post(name: .volumeDidChange, object: nil, userInfo: ["volume": finalVolume])
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
