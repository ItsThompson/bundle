import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsPanel: SettingsPanel?
    let authService = AuthService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock: equivalent to Info.plist LSUIElement = true
        NSApp.setActivationPolicy(.accessory)

        // Initialize settings panel
        settingsPanel = SettingsPanel(authService: authService)

        // Restore session from Keychain on launch
        Task {
            await authService.restoreSession()
        }
    }

    func openSettings() {
        settingsPanel?.toggle()
    }
}
