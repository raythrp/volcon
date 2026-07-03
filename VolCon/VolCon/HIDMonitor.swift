import Foundation
import IOKit.hid

class HIDMonitor {
    static let shared = HIDMonitor()

    private var hidManager: IOHIDManager?

    init() {}

    func startMonitoring() {
        checkInputMonitoringPermission()

        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let hidManager = hidManager else {
            print("VolCon: Failed to create IOHIDManager")
            return
        }

        // Match keyboard devices (built-in / USB keyboards with volume keys)
        // and Consumer Control devices (Bluetooth headphones, media remotes).
        // Device matching is by primary usage, not individual key usage — the
        // callback then filters for volume-specific usages.
        let matches: [CFDictionary] = [
            createMatchingDictionary(page: 0x07, usage: 0x01), // Keyboard
            createMatchingDictionary(page: 0x07, usage: 0x06), // Keyboard (alternate primary)
            createMatchingDictionary(page: 0x0C, usage: 0x01), // Consumer Control (Bluetooth headphones)
        ]
        IOHIDManagerSetDeviceMatchingMultiple(hidManager, matches as CFArray)

        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // Debug: log every device IOKit matches so we can confirm the headphone is seen
        IOHIDManagerRegisterDeviceMatchingCallback(hidManager, { ctx, _, _, device in
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "?"
            print("VolCon: HID device matched — '\(name)' [\(transport)]")
        }, context)

        IOHIDManagerRegisterInputValueCallback(hidManager, hidValueCallback, context)

        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            print("VolCon: Failed to open HID Manager: \(result)")
        } else {
            print("VolCon: HID Manager opened successfully")
        }
    }

    private func checkInputMonitoringPermission() {
        // IOHIDCheckAccess / IOHIDRequestAccess are available on macOS 10.15+.
        // Without Input Monitoring permission, IOHIDManagerOpen succeeds but
        // the callback silently never fires.
        let status = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch status {
        case kIOHIDAccessTypeGranted:
            print("VolCon: Input Monitoring permission granted.")
        case kIOHIDAccessTypeDenied:
            print("VolCon: Input Monitoring permission DENIED — go to System Settings > Privacy & Security > Input Monitoring and add VolCon.")
        default:
            print("VolCon: Input Monitoring permission unknown — requesting...")
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
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

    if usagePage == 0x07 { // Keyboard page
        if usage == 0x80 { direction = .up }
        else if usage == 0x81 { direction = .down }
    } else if usagePage == 0x0C { // Consumer page
        if usage == 0xE9 { direction = .up }
        else if usage == 0xEA { direction = .down }
    }

    guard let dir = direction else { return }

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
            let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? ""
            return .usb(vid: vid, pid: pid, productName: name)
        } else {
            return .fallback("BuiltIn")
        }
    }
}
