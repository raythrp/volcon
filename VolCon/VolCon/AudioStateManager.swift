import Foundation
import CoreAudio

class AudioStateManager {
    static let shared = AudioStateManager()
    
    /// Thread-safe cache of the target physical audio device
    private var internalCachedTargetDeviceID: AudioDeviceID?
    private let queue = DispatchQueue(label: "com.volcon.audiostate", attributes: .concurrent)
    
    var cachedTargetAudioDeviceID: AudioDeviceID? {
        get { queue.sync { internalCachedTargetDeviceID } }
        set { queue.async(flags: .barrier) { self.internalCachedTargetDeviceID = newValue } }
    }
    
    init() {
        updateActiveDevice()
        setupListeners()
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
            cachedTargetAudioDeviceID = nil
            return
        }
        
        printDeviceInfo(deviceID: defaultOutputID)
        
        // Attempt to fetch sub-devices directly (bypassing flaky deviceClass checks)
        // If this succeeds, it's a Multi-Output / Aggregate device!
        if let subDevice = fetchFirstPhysicalSubDevice(of: defaultOutputID) {
            cachedTargetAudioDeviceID = subDevice
            print("VolCon: Target physical sub-device selected: \(subDevice)")
        } else {
            cachedTargetAudioDeviceID = defaultOutputID
            print("VolCon: Target standard physical device selected: \(defaultOutputID)")
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
    
    private func fetchFirstPhysicalSubDevice(of aggregateID: AudioDeviceID) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            // FullSubDeviceList is much more reliable for Multi-Output devices than ActiveSubDeviceList
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList, 
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(aggregateID, &address, 0, nil, &size) != noErr {
            return nil
        }
        
        let subDeviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var subDevices = [AudioDeviceID](repeating: 0, count: subDeviceCount)
        
        if AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &size, &subDevices) == noErr {
            // Return the first valid active physical sub-device
            return subDevices.first(where: { $0 != 0 })
        }
        return nil
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
