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

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dynamically hide the dock icon (equivalent to LSUIElement = true)
        NSApp.setActivationPolicy(.accessory)
        
        setupMenuBar()
        requestAccessibilityPermissions()
        
        // Initialize Core Components
        _ = AudioStateManager.shared
        HIDMonitor.shared.startMonitoring()
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "VolCon")
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "VolCon is Active", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit VolCon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
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
