import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsPanel: SettingsPanel?
    private var retrievalPanel: RetrievalPanel?
    private let capturePalette = CapturePalette()
    private let screenshotCapture = ScreenshotCapture()
    private let noteEditor = NoteEditor()
    private let linkInput = LinkInput()

    // Shared dependencies
    private let localDatabase = LocalDatabase()
    private let tokenManager = TokenManager()
    private lazy var uploadService = ArtifactUploadService(tokenManager: tokenManager)
    private lazy var captureCoordinator = CaptureCoordinator(
        localDatabase: localDatabase,
        uploadService: uploadService,
        postCaptureThumbnail: PostCaptureThumbnail()
    )

    lazy var authService = AuthService(apiClient: APIClient(tokenManager: tokenManager), tokenManager: tokenManager)
    let hotkeyManager = HotkeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        requestAccessibilityIfNeeded()
        requestScreenCaptureIfNeeded()
        setupPanels()
        openDatabaseWithRetry()
        setupHotkey()
        Task { await authService.restoreSession() }
    }

    func openSettings() {
        settingsPanel?.toggle()
    }

    func showRetrievalPanel() {
        retrievalPanel?.toggle()
    }

    func showCapturePalette() {
        handleHotkeyPressed()
    }

    // MARK: - Setup

    private func setupPanels() {
        settingsPanel = SettingsPanel(
            authService: authService,
            hotkeyManager: hotkeyManager,
            artifactCountProvider: { [weak self] in
                (try? self?.localDatabase.getArtifactCount()) ?? 0
            }
        )
        retrievalPanel = RetrievalPanel(localDatabase: localDatabase)
    }

    private func setupHotkey() {
        hotkeyManager.onHotkeyPressed = { [weak self] in
            self?.handleHotkeyPressed()
        }
        hotkeyManager.register()
    }

    // MARK: - Database Open with Retry/Quit Alert

    private func openDatabaseWithRetry() {
        do {
            try localDatabase.open()
        } catch {
            showDatabaseOpenFailedAlert(error: error)
        }
    }

    private func showDatabaseOpenFailedAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Database Error"
        alert.informativeText = "Failed to open the local database: \(error.localizedDescription)"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openDatabaseWithRetry()
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Hotkey & Capture Dispatch

    private func handleHotkeyPressed() {
        capturePalette.show { [weak self] option in
            self?.handleCaptureOption(option)
        }
    }

    private func handleCaptureOption(_ option: CaptureOption) {
        switch option {
        case .screenshot:
            screenshotCapture.captureRegion { [weak self] output in
                guard let self, let output else { return }
                Task {
                    await self.captureCoordinator.handle(
                        .screenshot(fullPath: output.fullPath, thumbnailPath: output.thumbnailPath, createdAt: output.createdAt)
                    )
                }
            }
        case .note:
            noteEditor.show { [weak self] output in
                guard let self else { return }
                Task {
                    await self.captureCoordinator.handle(
                        .note(filePath: output.filePath, content: output.content, createdAt: output.createdAt)
                    )
                }
            }
        case .link:
            linkInput.show { [weak self] url in
                guard let self else { return }
                Task {
                    await self.captureCoordinator.handle(.link(url: url, createdAt: Date()))
                }
            }
        }
    }

    // MARK: - Permissions

    private func requestAccessibilityIfNeeded() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        let canPost = CGPreflightPostEventAccess()
        if !canPost {
            CGRequestPostEventAccess()
        }
    }

    private func requestScreenCaptureIfNeeded() {
        let hasAccess = CGPreflightScreenCaptureAccess()
        if !hasAccess {
            CGRequestScreenCaptureAccess()
        }
    }
}
