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

    var isBuiltIn: Bool { fallbackID != nil }

    /// Returns true if this fingerprint is identifiable within the given CoreAudio device UID string.
    func matches(uid: String) -> Bool {
        let uppercaseUID = uid.uppercased()

        if let mac = macAddress {
            // macAddress is already stripped of separators (see bluetooth() factory).
            // Strip separators from the UID too before checking containment.
            let cleanUID = uppercaseUID
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ":", with: "")
            return cleanUID.contains(mac)
        } else if let vid = vendorID, let pid = productID {
            let vidHex = String(format: "%04X", vid)
            let pidHex = String(format: "%04X", pid)
            return uppercaseUID.contains(vidHex) && uppercaseUID.contains(pidHex)
        } else if let fallback = fallbackID {
            return uppercaseUID.contains(fallback.uppercased())
        }

        return false
    }
}
