import AppKit
import SwiftUI

/// Settings panel: non-activating NSPanel that floats above other windows.
/// Contains auth UI, hotkey configuration, and account management.
final class SettingsPanel {
    private var panel: NSPanel?
    private let authService: AuthService
    private let hotkeyManager: HotkeyManager
    private let artifactCountProvider: () -> Int

    init(
        authService: AuthService,
        hotkeyManager: HotkeyManager,
        artifactCountProvider: @escaping () -> Int = { 0 }
    ) {
        self.authService = authService
        self.hotkeyManager = hotkeyManager
        self.artifactCountProvider = artifactCountProvider
    }

    func toggle() {
        if let panel = panel, panel.isVisible {
            close()
        } else {
            open()
        }
    }

    func open() {
        if let existing = panel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = SettingsContentView(
            authService: authService,
            hotkeyManager: hotkeyManager,
            artifactCount: artifactCountProvider()
        )
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 380, height: 560)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Bundle Settings"
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
    }
}

// MARK: - Settings Content View

/// Root view for the settings panel: shows auth, hotkey, and account sections.
private struct SettingsContentView: View {
    @ObservedObject var authService: AuthService
    @ObservedObject var hotkeyManager: HotkeyManager
    let artifactCount: Int

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if authService.isAuthenticated {
                    HotkeyConfigView(hotkeyManager: hotkeyManager)
                    Divider()
                    AccountView(authService: authService, artifactCount: artifactCount)
                    Divider()
                    logoutSection
                } else {
                    AuthView(authService: authService)
                }
            }
            .padding()
        }
        .frame(minWidth: 340, minHeight: 400)
    }

    private var logoutSection: some View {
        Button("Log Out") {
            Task { await authService.logout() }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 8)
    }
}
