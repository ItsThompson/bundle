import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Result of a screenshot capture operation.
struct CaptureResult {
    let fullPath: URL
    let thumbnailPath: URL
    let artifactId: String
    let createdAt: Date
}

/// Handles screen region selection and PNG capture.
/// Uses ScreenCaptureKit (SCScreenshotManager) for the actual screenshot.
@MainActor
final class ScreenshotCapture {
    private var overlayWindow: NSWindow?
    private var selectionView: RegionSelectionView?

    /// Begin region selection mode. Calls completion with the capture result on success,
    /// or nil if the user cancels (Escape).
    func captureRegion(completion: @escaping (CaptureResult?) -> Void) {
        guard let screen = NSScreen.main else {
            completion(nil)
            return
        }

        let screenFrame = screen.frame

        // Create a transparent overlay window covering the entire screen
        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = NSColor.black.withAlphaComponent(0.2)
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let selectionView = RegionSelectionView(frame: screenFrame)
        selectionView.onComplete = { [weak self] rect in
            self?.finishCapture(rect: rect, screen: screen, completion: completion)
        }
        selectionView.onCancel = { [weak self] in
            self?.dismissOverlay()
            completion(nil)
        }

        window.contentView = selectionView
        window.makeKeyAndOrderFront(nil)

        // Set crosshair cursor
        NSCursor.crosshair.push()

        self.overlayWindow = window
        self.selectionView = selectionView
    }

    private func finishCapture(rect: NSRect, screen: NSScreen, completion: @escaping (CaptureResult?) -> Void) {
        dismissOverlay()

        // Convert from screen coordinates (origin bottom-left) to CG coordinates (origin top-left)
        let screenHeight = screen.frame.height
        let cgRect = CGRect(
            x: rect.origin.x,
            y: screenHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )

        // Capture the screen region via ScreenCaptureKit
        Task {
            let cgImage = await Self.captureScreen(rect: cgRect, screen: screen)
            guard let cgImage else {
                completion(nil)
                return
            }
            let result = saveCapture(image: cgImage)
            completion(result)
        }
    }

    private func dismissOverlay() {
        NSCursor.pop()
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        selectionView = nil
    }

    /// Capture a screen region using ScreenCaptureKit's SCScreenshotManager.
    private static func captureScreen(rect: CGRect, screen: NSScreen) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            // Find the SCDisplay matching the target NSScreen
            guard let display = content.displays.first(where: { display in
                display.frame == screen.frame
            }) ?? content.displays.first else {
                return nil
            }

            // Exclude our own app's windows from the capture
            let excludedApps = content.applications.filter { app in
                app.bundleIdentifier == Bundle.main.bundleIdentifier
            }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )

            let config = SCStreamConfiguration()
            config.sourceRect = rect
            config.width = Int(rect.width) * Int(screen.backingScaleFactor)
            config.height = Int(rect.height) * Int(screen.backingScaleFactor)
            config.showsCursor = false

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            print("[Bundle] ScreenCaptureKit capture failed: \(error)")
            return nil
        }
    }

    // MARK: - File Save

    private func saveCapture(image: CGImage) -> CaptureResult? {
        let now = Date()
        let artifactId = UUID().uuidString.lowercased()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd"
        let dateStr = dateFormatter.string(from: now)

        let baseDir = artifactsDirectory.appendingPathComponent(dateStr)

        // Ensure directory exists
        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        } catch {
            print("[Bundle] Failed to create artifacts directory: \(error)")
            return nil
        }

        let fullPath = baseDir.appendingPathComponent("\(artifactId).png")
        let thumbnailPath = baseDir.appendingPathComponent("\(artifactId)_thumb.png")

        // Save full resolution PNG
        guard savePNG(image: image, to: fullPath) else {
            return nil
        }

        // Generate and save 300px-wide thumbnail
        let thumbnail = generateThumbnail(from: image, maxWidth: 300)
        if let thumbnail = thumbnail {
            _ = savePNG(image: thumbnail, to: thumbnailPath)
        }

        return CaptureResult(
            fullPath: fullPath,
            thumbnailPath: thumbnailPath,
            artifactId: artifactId,
            createdAt: now
        )
    }

    private func savePNG(image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    private func generateThumbnail(from image: CGImage, maxWidth: Int) -> CGImage? {
        let originalWidth = image.width
        let originalHeight = image.height

        guard originalWidth > maxWidth else {
            return image // Already small enough
        }

        let scale = CGFloat(maxWidth) / CGFloat(originalWidth)
        let newWidth = Int(CGFloat(originalWidth) * scale)
        let newHeight = Int(CGFloat(originalHeight) * scale)

        guard let context = CGContext(
            data: nil,
            width: newWidth,
            height: newHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage()
    }

    // MARK: - Paths

    private var artifactsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Bundle/artifacts")
    }
}

// MARK: - Region Selection View

/// Custom NSView that handles mouse drag to select a rectangular region.
private class RegionSelectionView: NSView {
    var onComplete: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)

        let rect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        currentRect = rect
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = currentRect, rect.width > 10, rect.height > 10 else {
            // Too small: treat as a cancel
            startPoint = nil
            currentRect = nil
            needsDisplay = true
            return
        }

        onComplete?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let rect = currentRect else { return }

        // Draw selection rectangle
        NSColor.systemBlue.withAlphaComponent(0.2).setFill()
        NSBezierPath(rect: rect).fill()

        NSColor.systemBlue.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2.0
        path.stroke()
    }
}
