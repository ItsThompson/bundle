import AppKit
import SwiftUI

/// Content types the post-capture thumbnail can display.
enum ThumbnailContent {
    /// Screenshot capture: display the image thumbnail.
    case screenshot(fullPath: URL, thumbnailPath: URL)
    /// Note capture: display first 2-3 lines of text.
    case note(text: String)
    /// Link capture: display extracted domain name.
    case link(url: String)

    /// The copyable value for this content.
    var copyableValue: CopyableContent {
        switch self {
        case .screenshot(let fullPath, let thumbnailPath):
            return .imageFile(primary: fullPath, fallback: thumbnailPath)
        case .note(let text):
            return .text(text)
        case .link(let url):
            return .text(url)
        }
    }
}

/// What gets placed on the clipboard when "Copy" is pressed.
enum CopyableContent {
    case imageFile(primary: URL, fallback: URL)
    case text(String)
}

/// Manages the post-capture thumbnail overlay window.
/// Shows a brief preview in the bottom-right corner after any capture.
/// Auto-dismisses after 5 seconds. On hover, reveals action buttons.
@MainActor
final class PostCaptureThumbnail {
    private var window: NSWindow?
    private var dismissTimer: Timer?

    /// Callbacks for thumbnail actions.
    var onCopy: ((ThumbnailContent) -> Void)?
    var onAddNote: ((String) -> Void)?

    private static let thumbnailWidth: CGFloat = 200
    private static let edgeMargin: CGFloat = 16
    private static let dismissDelay: TimeInterval = 5.0

    /// Show a thumbnail overlay for the given content.
    /// - Parameters:
    ///   - content: What to display in the thumbnail.
    ///   - artifactId: The ID of the captured artifact (used for "Add Note" action).
    func show(content: ThumbnailContent, artifactId: String) {
        // Remove any existing thumbnail first
        dismiss()

        let height = Self.computeHeight(for: content)
        let frame = Self.computeFrame(width: Self.thumbnailWidth, height: height)

        let window = NonActivatingWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // AeroSpace-safe window properties (per spec §04)
        window.level = .screenSaver
        // Note: canBecomeKey and canBecomeMain are handled by NonActivatingWindow subclass
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.hasShadow = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false

        let thumbnailView = ThumbnailOverlayView(
            content: content,
            onCopy: { [weak self] in
                self?.onCopy?(content)
                self?.dismiss()
            },
            onAddNote: { [weak self] in
                self?.onAddNote?(artifactId)
                self?.dismiss()
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        let hostingView = NSHostingView(rootView: thumbnailView)
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        window.contentView = hostingView

        window.orderFrontRegardless()
        self.window = window

        // Start auto-dismiss timer
        startDismissTimer()
    }

    /// Immediately dismiss the thumbnail overlay.
    func dismiss() {
        cancelDismissTimer()
        window?.orderOut(nil)
        window = nil
    }

    /// Whether the thumbnail is currently visible.
    var isVisible: Bool {
        window?.isVisible ?? false
    }

    // MARK: - Timer Management

    private func startDismissTimer() {
        cancelDismissTimer()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: Self.dismissDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss()
            }
        }
    }

    private func cancelDismissTimer() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    // MARK: - Layout Computation

    private static func computeHeight(for content: ThumbnailContent) -> CGFloat {
        switch content {
        case .screenshot:
            // Image thumbnail: ~150px height typical (aspect-preserved, will be capped)
            return 160
        case .note:
            // Text preview: compact
            return 100
        case .link:
            // Domain name display: compact
            return 80
        }
    }

    private static func computeFrame(width: CGFloat, height: CGFloat) -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 0, y: 0, width: width, height: height)
        }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.maxX - width - edgeMargin,
            y: visibleFrame.minY + edgeMargin
        )

        return NSRect(origin: origin, size: NSSize(width: width, height: height))
    }
}

// MARK: - Text Utilities

/// Utilities for thumbnail content formatting.
enum ThumbnailTextUtils {
    /// Extracts the domain name from a URL string.
    static func extractDomain(from urlString: String) -> String {
        guard let url = URL(string: urlString),
              let host = url.host else {
            // Fallback: try to parse manually
            let stripped = urlString
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
            return stripped.components(separatedBy: "/").first ?? urlString
        }
        // Remove "www." prefix if present
        if host.hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }

    /// Truncates text to the first 3 lines for thumbnail preview.
    static func truncateForPreview(_ text: String, maxLines: Int = 3) -> String {
        let lines = text.components(separatedBy: .newlines)
        let previewLines = Array(lines.prefix(maxLines))
        return previewLines.joined(separator: "\n")
    }
}

// MARK: - Non-Activating Window

/// NSWindow subclass that never becomes key or main.
/// Used for the post-capture thumbnail overlay to avoid stealing focus.
private class NonActivatingWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
