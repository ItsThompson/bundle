import AppKit
import SwiftUI

/// Settings panel: non-activating NSPanel that floats above other windows.
/// Contains auth UI and (future) hotkey configuration.
final class SettingsPanel {
    private var panel: NSPanel?
    private let authService: AuthService

    init(authService: AuthService) {
        self.authService = authService
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

        let contentView = SettingsContentView(authService: authService)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 400)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
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

/// Root view for the settings panel: shows auth section.
private struct SettingsContentView: View {
    @ObservedObject var authService: AuthService

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                AuthView(authService: authService)
            }
            .padding()
        }
        .frame(minWidth: 320, minHeight: 300)
    }
}
