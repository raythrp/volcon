import Foundation

/// A unified fingerprint to match physical hardware devices between IOKit and CoreAudio.
struct HardwareFingerprint: Equatable {
    let macAddress: String?
    let vendorID: Int?
    let productID: Int?
    let fallbackID: String?
    
    /// Initialize for a Bluetooth device
    static func bluetooth(mac: String) -> HardwareFingerprint {
        return HardwareFingerprint(macAddress: mac.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").uppercased(),
                                   vendorID: nil, productID: nil, fallbackID: nil)
    }
    
    /// Initialize for a USB device
    static func usb(vid: Int, pid: Int) -> HardwareFingerprint {
        return HardwareFingerprint(macAddress: nil, vendorID: vid, productID: pid, fallbackID: nil)
    }
    
    /// Initialize for built-in or other fallback devices
    static func fallback(_ id: String) -> HardwareFingerprint {
        return HardwareFingerprint(macAddress: nil, vendorID: nil, productID: nil, fallbackID: id)
    }
}
