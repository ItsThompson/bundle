import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock: equivalent to Info.plist LSUIElement = true
        NSApp.setActivationPolicy(.accessory)
    }
}
