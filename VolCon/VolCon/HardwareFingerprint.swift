import Foundation

/// A unified fingerprint to match physical hardware devices between IOKit and CoreAudio.
struct HardwareFingerprint: Equatable {
    let macAddress: String?
    let vendorID: Int?
    let productID: Int?
    let fallbackID: String?
    let productName: String?

    /// Initialize for a Bluetooth device
    static func bluetooth(mac: String) -> HardwareFingerprint {
        return HardwareFingerprint(macAddress: mac.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "").uppercased(),
                                   vendorID: nil, productID: nil, fallbackID: nil, productName: nil)
    }

    /// Initialize for a USB device
    static func usb(vid: Int, pid: Int, productName: String) -> HardwareFingerprint {
        return HardwareFingerprint(macAddress: nil, vendorID: vid, productID: pid, fallbackID: nil,
                                   productName: productName.isEmpty ? nil : productName)
    }

    /// Initialize for built-in or other fallback devices
    static func fallback(_ id: String) -> HardwareFingerprint {
        return HardwareFingerprint(macAddress: nil, vendorID: nil, productID: nil, fallbackID: id, productName: nil)
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
            // AppleUSBAudioEngine UIDs embed the product name, not VID/PID hex:
            // "AppleUSBAudioEngine:<mfr>:<product>:<serial>:<interface>"
            // Match by product name first; fall back to VID/PID hex for other drivers.
            if let name = productName {
                return uppercaseUID.contains(name.uppercased())
            }
            let vidHex = String(format: "%04X", vid)
            let pidHex = String(format: "%04X", pid)
            return uppercaseUID.contains(vidHex) && uppercaseUID.contains(pidHex)
        } else if let fallback = fallbackID {
            return uppercaseUID.contains(fallback.uppercased())
        }

        return false
    }
}
