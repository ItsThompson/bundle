import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsPanel: SettingsPanel?
    private let capturePalette = CapturePalette()
    private let screenshotCapture = ScreenshotCapture()
    private let localDatabase = LocalDatabase()
    private let artifactUploadService = ArtifactUploadService()

    let authService = AuthService()
    let hotkeyManager = HotkeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock: equivalent to Info.plist LSUIElement = true
        NSApp.setActivationPolicy(.accessory)

        // Initialize settings panel with hotkey manager and artifact count
        settingsPanel = SettingsPanel(
            authService: authService,
            hotkeyManager: hotkeyManager,
            artifactCountProvider: { [weak self] in
                (try? self?.localDatabase.getArtifactCount()) ?? 0
            }
        )

        // Open local database
        do {
            try localDatabase.open()
        } catch {
            print("[Bundle] Failed to open local database: \(error)")
        }

        // Register global hotkey
        hotkeyManager.onHotkeyPressed = { [weak self] in
            self?.handleHotkeyPressed()
        }
        hotkeyManager.register()

        // Restore session from Keychain on launch
        Task {
            await authService.restoreSession()
        }
    }

    func openSettings() {
        settingsPanel?.toggle()
    }

    // MARK: - Hotkey Handler

    private func handleHotkeyPressed() {
        capturePalette.show { [weak self] option in
            self?.handleCaptureOption(option)
        }
    }

    // MARK: - Capture Flow

    private func handleCaptureOption(_ option: CaptureOption) {
        switch option {
        case .screenshot:
            startScreenshotCapture()
        case .note:
            // Implemented in ticket #7
            print("[Bundle] Note capture not yet implemented")
        case .link:
            // Implemented in ticket #8
            print("[Bundle] Link capture not yet implemented")
        }
    }

    private func startScreenshotCapture() {
        screenshotCapture.captureRegion { [weak self] result in
            guard let self = self, let result = result else { return }
            self.handleCaptureResult(result)
        }
    }

    private func handleCaptureResult(_ result: CaptureResult) {
        // 1. Insert into local SQLite with status "pending"
        do {
            let relativePath = result.fullPath.lastPathComponent
            try localDatabase.insertArtifact(
                id: result.artifactId,
                type: "screenshot",
                contentPath: relativePath,
                contentText: nil,
                status: "pending",
                createdAt: result.createdAt
            )
        } catch {
            print("[Bundle] Failed to insert artifact into local DB: \(error)")
        }

        // 2. Upload to backend asynchronously (non-blocking)
        Task {
            let response = await artifactUploadService.uploadArtifact(
                fileURL: result.fullPath,
                type: "screenshot",
                createdAt: result.createdAt
            )

            if let response = response {
                // Update local DB with backend ID and synced status
                try? localDatabase.updateArtifactStatus(
                    id: result.artifactId,
                    status: response.status
                )
                print("[Bundle] Screenshot uploaded: \(response.id)")
            } else {
                // Upload failed: artifact stays "pending" for retry
                print("[Bundle] Screenshot upload failed, will retry later")
            }
        }
    }
}
