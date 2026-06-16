import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsPanel: SettingsPanel?
    private var retrievalPanel: RetrievalPanel?
    private let capturePalette = CapturePalette()
    private let screenshotCapture = ScreenshotCapture()
    private let noteEditor = NoteEditor()
    private let linkInput = LinkInput()
    private let postCaptureThumbnail = PostCaptureThumbnail()
    private let localDatabase = LocalDatabase()
    private let tokenManager = TokenManager()
    private lazy var artifactUploadService = ArtifactUploadService(tokenManager: tokenManager)

    lazy var authService = AuthService(apiClient: APIClient(tokenManager: tokenManager), tokenManager: tokenManager)
    let hotkeyManager = HotkeyManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock: equivalent to Info.plist LSUIElement = true
        NSApp.setActivationPolicy(.accessory)

        // Check and prompt for Accessibility permissions (required for global hotkey)
        requestAccessibilityIfNeeded()

        // Check and prompt for Screen Recording permission (required for ScreenCaptureKit)
        requestScreenCaptureIfNeeded()

        // Initialize settings panel with hotkey manager and artifact count
        settingsPanel = SettingsPanel(
            authService: authService,
            hotkeyManager: hotkeyManager,
            artifactCountProvider: { [weak self] in
                (try? self?.localDatabase.getArtifactCount()) ?? 0
            }
        )

        // Initialize retrieval panel
        retrievalPanel = RetrievalPanel(localDatabase: localDatabase)

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

    func showRetrievalPanel() {
        retrievalPanel?.toggle()
    }

    // MARK: - Accessibility Permissions

    private func requestAccessibilityIfNeeded() {
        let trusted = AXIsProcessTrusted()
        print("[Bundle] AXIsProcessTrusted: \(trusted)")

        if !trusted {
            // Trigger the system prompt to open System Settings → Accessibility
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            print("[Bundle] Accessibility permission not granted. System prompt triggered.")
            print("[Bundle] Also grant Input Monitoring in System Settings → Privacy & Security → Input Monitoring")
        }

        // On macOS Sequoia+, CGEvent taps also require Input Monitoring permission
        let canPost = CGPreflightPostEventAccess()
        print("[Bundle] CGPreflightPostEventAccess: \(canPost)")
        if !canPost {
            // Request post event access (triggers Input Monitoring prompt)
            CGRequestPostEventAccess()
            print("[Bundle] Input Monitoring permission not granted. Requesting access.")
        }
    }

    // MARK: - Screen Capture Permissions

    private func requestScreenCaptureIfNeeded() {
        let hasAccess = CGPreflightScreenCaptureAccess()
        print("[Bundle] CGPreflightScreenCaptureAccess: \(hasAccess)")

        if !hasAccess {
            // Triggers the system prompt directing user to System Settings → Screen Recording
            let granted = CGRequestScreenCaptureAccess()
            print("[Bundle] CGRequestScreenCaptureAccess result: \(granted)")
            if !granted {
                print("[Bundle] Screen Recording permission not granted. Enable in System Settings → Privacy & Security → Screen Recording")
            }
        }
    }

    // MARK: - Hotkey Handler

    func showCapturePalette() {
        handleHotkeyPressed()
    }

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
            startNoteCapture()
        case .link:
            startLinkCapture()
        }
    }

    private func startNoteCapture() {
        noteEditor.show { [weak self] result in
            guard let self = self else { return }
            self.handleNoteCaptureResult(result)
        }
    }

    private func handleNoteCaptureResult(_ result: NoteCaptureResult) {
        // 1. Insert into local SQLite with status "pending"
        do {
            let relativePath = Self.relativePath(for: result.filePath)
            try localDatabase.insertArtifact(
                id: result.artifactId,
                type: "note",
                contentPath: relativePath,
                contentText: result.content,
                status: "pending",
                createdAt: result.createdAt
            )
        } catch {
            print("[Bundle] Failed to insert note artifact into local DB: \(error)")
        }

        // 2. Show post-capture thumbnail
        showPostCaptureThumbnail(
            content: .note(text: result.content),
            artifactId: result.artifactId
        )

        // 3. Upload to backend asynchronously (non-blocking)
        Task {
            let response = await artifactUploadService.uploadArtifact(
                fileURL: result.filePath,
                type: "note",
                createdAt: result.createdAt
            )

            if let response = response {
                try? localDatabase.replaceArtifactId(
                    oldId: result.artifactId,
                    newId: response.id.uuidString,
                    status: response.status
                )
                print("[Bundle] Note uploaded: \(response.id)")
            } else {
                print("[Bundle] Note upload failed, will retry later")
            }
        }
    }

    // MARK: - Link Capture

    private func startLinkCapture() {
        linkInput.show { [weak self] url in
            guard let self = self else { return }
            self.handleLinkCaptured(url)
        }
    }

    private func handleLinkCaptured(_ url: String) {
        let artifactId = UUID().uuidString
        let createdAt = Date()

        // 1. Insert into local SQLite with type "link", content_text = URL
        do {
            try localDatabase.insertArtifact(
                id: artifactId,
                type: "link",
                contentPath: nil,
                contentText: url,
                status: "pending",
                createdAt: createdAt
            )
        } catch {
            print("[Bundle] Failed to insert link artifact into local DB: \(error)")
        }

        // 2. Show post-capture thumbnail
        showPostCaptureThumbnail(
            content: .link(url: url),
            artifactId: artifactId
        )

        // 3. Upload to backend asynchronously (non-blocking)
        Task {
            let response = await artifactUploadService.uploadLink(
                url: url,
                createdAt: createdAt
            )

            if let response = response {
                try? localDatabase.replaceArtifactId(
                    oldId: artifactId,
                    newId: response.id.uuidString,
                    status: response.status
                )
                print("[Bundle] Link uploaded: \(response.id)")
            } else {
                print("[Bundle] Link upload failed, will retry later")
            }
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
            let relativePath = Self.relativePath(for: result.fullPath)
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

        // 2. Show post-capture thumbnail
        showPostCaptureThumbnail(
            content: .screenshot(fullPath: result.fullPath, thumbnailPath: result.thumbnailPath),
            artifactId: result.artifactId
        )

        // 3. Upload to backend asynchronously (non-blocking)
        Task {
            let response = await artifactUploadService.uploadArtifact(
                fileURL: result.fullPath,
                type: "screenshot",
                createdAt: result.createdAt
            )

            if let response = response {
                // Replace local ID with backend ID so sync won't create a duplicate
                try? localDatabase.replaceArtifactId(
                    oldId: result.artifactId,
                    newId: response.id.uuidString,
                    status: response.status
                )
                print("[Bundle] Screenshot uploaded: \(response.id)")
            } else {
                // Upload failed: artifact stays "pending" for retry
                print("[Bundle] Screenshot upload failed, will retry later")
            }
        }
    }

    // MARK: - Post-Capture Thumbnail

    private func showPostCaptureThumbnail(content: ThumbnailContent, artifactId: String) {
        postCaptureThumbnail.onCopy = { [weak self] thumbnailContent in
            self?.copyContentToClipboard(thumbnailContent)
        }
        postCaptureThumbnail.onAddNote = { [weak self] id in
            self?.openNoteEditorForArtifact(id)
        }
        postCaptureThumbnail.show(content: content, artifactId: artifactId)
    }

    private func copyContentToClipboard(_ content: ThumbnailContent) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch content.copyableValue {
        case .imageFile(let primary, let fallback):
            if let image = NSImage(contentsOf: primary) {
                pasteboard.writeObjects([image])
            } else if let image = NSImage(contentsOf: fallback) {
                pasteboard.writeObjects([image])
            }
        case .text(let string):
            pasteboard.setString(string, forType: .string)
        }
    }

    private func openNoteEditorForArtifact(_ artifactId: String) {
        // TODO: Open note editor pre-linked to artifact (future ticket)
        print("[Bundle] Add Note for artifact: \(artifactId)")
    }

    // MARK: - Path Helpers

    /// Compute relative path from the artifacts base directory.
    /// e.g., "/Users/.../Bundle/artifacts/2026/06/11/abc.png" → "2026/06/11/abc.png"
    private static func relativePath(for fileURL: URL) -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let artifactsDir = appSupport.appendingPathComponent("Bundle/artifacts").path + "/"
        let fullPath = fileURL.path
        if fullPath.hasPrefix(artifactsDir) {
            return String(fullPath.dropFirst(artifactsDir.count))
        }
        return fileURL.lastPathComponent
    }
}
