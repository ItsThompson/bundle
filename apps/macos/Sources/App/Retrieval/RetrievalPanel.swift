import AppKit
import SwiftUI

/// Manages the retrieval panel: a floating, non-activating NSPanel that
/// displays the artifact grid. Opened from the menubar "Show Artifacts" item.
@MainActor
final class RetrievalPanel {
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private let localDatabase: LocalDatabase
    private let syncService: SyncService
    private let navigationState = RetrievalNavigationState()

    init(localDatabase: LocalDatabase, syncService: SyncService? = nil) {
        self.localDatabase = localDatabase
        self.syncService = syncService ?? SyncService(localDatabase: localDatabase)
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Show the retrieval panel. If already visible, brings it to front.
    func show() {
        if let existing = panel, existing.isVisible {
            existing.orderFrontRegardless()
            return
        }

        createPanel()
        installDismissMonitors()
        syncService.start()
    }

    /// Dismiss the retrieval panel.
    func dismiss() {
        syncService.stop()
        removeDismissMonitors()
        panel?.orderOut(nil)
        panel = nil
    }

    /// Toggle panel visibility.
    func toggle() {
        if isVisible {
            dismiss()
        } else {
            show()
        }
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let width: CGFloat = 620
        let height: CGFloat = 700

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let origin = NSPoint(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        let contentView = RetrievalContentView(localDatabase: localDatabase, syncService: syncService, navigationState: navigationState)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.contentView = hostingView

        panel.orderFrontRegardless()
        self.panel = panel
    }

    // MARK: - Dismiss Monitors

    private func installDismissMonitors() {
        // Clicking outside the panel dismisses it
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let panel = self.panel else { return }
            let panelFrame = panel.frame

            // Convert to screen coordinates for global monitor
            let screenPoint = NSEvent.mouseLocation
            if !panelFrame.contains(screenPoint) {
                self.dismiss()
            }
        }

        // Escape key: navigates back from detail, or dismisses panel from grid
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // kVK_Escape
                guard let self = self else { return event }
                if self.navigationState.isShowingDetail {
                    self.navigationState.onBack?()
                } else {
                    self.dismiss()
                }
                return nil
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}
