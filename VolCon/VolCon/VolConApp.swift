import SwiftUI
import ApplicationServices

@main
struct VolConApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // Empty Settings scene since this is a pure Menu Bar app
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    private var volumeResetTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()
        requestAccessibilityPermissions()

        _ = AudioStateManager.shared
        HIDMonitor.shared.startMonitoring()

        NotificationCenter.default.addObserver(self, selector: #selector(handleVolumeChange(_:)), name: .volumeDidChange, object: nil)
    }

    @objc private func handleVolumeChange(_ notification: Notification) {
        guard let volume = notification.userInfo?["volume"] as? Float32 else { return }
        showVolumeBadge(volume: volume)
    }

    private func showVolumeBadge(volume: Float32) {
        let symbolName: String
        switch volume {
        case 0:          symbolName = "speaker.slash.fill"
        case ..<0.34:    symbolName = "speaker.wave.1.fill"
        case ..<0.67:    symbolName = "speaker.wave.2.fill"
        default:         symbolName = "speaker.wave.3.fill"
        }

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "VolCon")
            button.title = " \(Int(volume * 100))%"
            button.imagePosition = .imageLeft
        }

        volumeResetTimer?.invalidate()
        volumeResetTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.resetMenuBarIcon()
        }
    }

    private func resetMenuBarIcon() {
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "VolCon")
            button.title = ""
        }
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "VolCon")
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    // Rebuilds the menu each time it opens so the device list and checkmarks
    // reflect live state (connected devices + current group membership).
    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let activeItem = NSMenuItem(title: "VolCon is Active", action: nil, keyEquivalent: "")
        activeItem.isEnabled = false
        menu.addItem(activeItem)
        menu.addItem(NSMenuItem.separator())

        let header = NSMenuItem(title: "Output Devices", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let devices = MultiOutputManager.shared.listOutputDevices()
        let members = Set(MultiOutputManager.shared.currentMemberUIDs())

        if devices.isEmpty {
            let empty = NSMenuItem(title: "No output devices found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for device in devices {
                let item = NSMenuItem(title: device.name, action: #selector(toggleDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.uid
                item.state = members.contains(device.uid) ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VolCon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        var members = Set(MultiOutputManager.shared.currentMemberUIDs())
        if members.contains(uid) {
            members.remove(uid)
        } else {
            members.insert(uid)
        }
        MultiOutputManager.shared.setMembers(Array(members))
    }
    
    private func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if !accessEnabled {
            print("WARNING: Accessibility permissions are required for global media key monitoring.")
            
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permissions Required"
                alert.informativeText = "VolCon requires Accessibility permissions to intercept media keys when the app is in the background.\n\nPlease enable VolCon in System Settings > Privacy & Security > Accessibility, then restart the application."
                alert.alertStyle = .critical
                alert.addButton(withTitle: "Open System Settings & Quit")
                alert.addButton(withTitle: "Quit")
                
                // Keep the alert on top of other windows
                alert.window.level = .floating
                NSApp.activate(ignoringOtherApps: true)
                
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    if let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                }
                
                NSApp.terminate(nil)
            }
        }
    }
}
