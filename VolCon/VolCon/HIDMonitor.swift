import Foundation
import IOKit.hid

class HIDMonitor {
    static let shared = HIDMonitor()
    
    private var hidManager: IOHIDManager?
    
    init() {}
    
    func startMonitoring() {
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        
        guard let hidManager = hidManager else {
            print("Failed to create IOHIDManager")
            return
        }
        
        // Define usages using hardcoded constants in case headers are missing some
        let kHIDPage_KeyboardOrKeypad = 0x07
        let kHIDPage_Consumer = 0x0C
        
        let kHIDUsage_KeyboardVolumeUp = 0x80
        let kHIDUsage_KeyboardVolumeDown = 0x81
        let kHIDUsage_Csmr_VolumeUp = 0xE9
        let kHIDUsage_Csmr_VolumeDown = 0xEA
        
        let keyboardUpDict = createMatchingDictionary(page: kHIDPage_KeyboardOrKeypad, usage: kHIDUsage_KeyboardVolumeUp)
        let keyboardDownDict = createMatchingDictionary(page: kHIDPage_KeyboardOrKeypad, usage: kHIDUsage_KeyboardVolumeDown)
        
        let consumerUpDict = createMatchingDictionary(page: kHIDPage_Consumer, usage: kHIDUsage_Csmr_VolumeUp)
        let consumerDownDict = createMatchingDictionary(page: kHIDPage_Consumer, usage: kHIDUsage_Csmr_VolumeDown)
        
        let matches = [keyboardUpDict, keyboardDownDict, consumerUpDict, consumerDownDict]
        IOHIDManagerSetDeviceMatchingMultiple(hidManager, matches as CFArray)
        
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerRegisterInputValueCallback(hidManager, hidValueCallback, context)
        
        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        
        let result = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            print("Failed to open HID Manager: \(result)")
        }
    }
    
    private func createMatchingDictionary(page: Int, usage: Int) -> CFDictionary {
        let dict = NSMutableDictionary()
        dict[kIOHIDDeviceUsagePageKey] = page
        dict[kIOHIDDeviceUsageKey] = usage
        return dict as CFDictionary
    }
}

let hidValueCallback: IOHIDValueCallback = { context, result, sender, value in
    guard let context = context else { return }
    let monitor = Unmanaged<HIDMonitor>.fromOpaque(context).takeUnretainedValue()
    
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)
    
    // Only process key press (1), ignore release (0)
    guard intValue == 1 else { return }
    
    var direction: VolumeExecutor.VolumeDirection?
    
    // Hardware Constants
    if usagePage == 0x07 { // Keyboard
        if usage == 0x80 { direction = .up }
        else if usage == 0x81 { direction = .down }
    } else if usagePage == 0x0C { // Consumer
        if usage == 0xE9 { direction = .up }
        else if usage == 0xEA { direction = .down }
    }
    
    guard let dir = direction else { return }
    
    // Extract hardware fingerprint
    let device = IOHIDElementGetDevice(element)
    let fingerprint = monitor.extractFingerprint(from: device)
    
    VolumeExecutor.shared.executeVolumeChange(direction: dir, for: fingerprint)
}

extension HIDMonitor {
    func extractFingerprint(from device: IOHIDDevice) -> HardwareFingerprint {
        let transportType = (IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String) ?? ""
        
        if transportType == "Bluetooth" {
            let mac = (IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String) ?? ""
            return .bluetooth(mac: mac)
        } else if transportType == "USB" {
            let vid = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
            let pid = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? 0
            return .usb(vid: vid, pid: pid)
        } else {
            return .fallback("BuiltIn")
        }
    }
}
