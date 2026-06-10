import AppKit
import SwiftUI

/// Callback type for when a URL is submitted from the link input panel.
typealias LinkInputHandler = (String) -> Void

/// Manages the link input NSPanel: a floating, non-activating panel
/// with a single URL text field, pre-filled from clipboard if applicable.
@MainActor
final class LinkInput {
    private var panel: NSPanel?
    private var onSave: LinkInputHandler?
    private var localMonitor: Any?

    /// Maximum allowed URL length.
    static let maxURLLength = 2048

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Show the link input panel centered on the active screen.
    /// Pre-fills the URL field from clipboard if it contains a valid URL.
    func show(onSave: @escaping LinkInputHandler) {
        if isVisible {
            dismiss()
            return
        }

        self.onSave = onSave
        let clipboardURL = urlFromClipboard()
        createPanel(prefillURL: clipboardURL)
    }

    /// Dismiss the panel without saving.
    func dismiss() {
        removeKeyboardMonitor()
        panel?.orderOut(nil)
        panel = nil
        onSave = nil
    }

    // MARK: - Panel Creation

    private func createPanel(prefillURL: String?) {
        let width: CGFloat = 420
        let height: CGFloat = 100

        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let origin = NSPoint(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2
        )

        let panel = KeyablePanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let contentView = LinkInputView(
            initialURL: prefillURL ?? "",
            onSubmit: { [weak self] url in
                self?.handleSubmit(url)
            },
            onCancel: { [weak self] in
                self?.dismiss()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.contentView = hostingView

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        installKeyboardMonitor()
    }

    // MARK: - Keyboard Monitor

    private func installKeyboardMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            // Escape dismisses
            if event.keyCode == 53 { // kVK_Escape
                self.dismiss()
                return nil
            }
            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    // MARK: - Submission

    private func handleSubmit(_ url: String) {
        let handler = onSave
        dismiss()
        handler?(url)
    }

    // MARK: - Clipboard

    /// Check if the clipboard contains a valid URL and return it.
    private func urlFromClipboard() -> String? {
        let pasteboard = NSPasteboard.general

        // Try URL type first
        if let urlString = pasteboard.string(forType: .URL),
           Self.isValidURL(urlString) {
            return urlString
        }

        // Fall back to plain string and check if it looks like a URL
        if let string = pasteboard.string(forType: .string),
           Self.isValidURL(string) {
            return string
        }

        return nil
    }

    // MARK: - Validation

    /// Validate that a string is a valid URL starting with http:// or https://
    /// and does not exceed the max length.
    static func isValidURL(_ urlString: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else { return false }
        guard trimmed.count <= maxURLLength else { return false }

        let lowercased = trimmed.lowercased()
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else {
            return false
        }

        // Basic format validation: must have something after the scheme
        guard let url = URL(string: trimmed),
              let host = url.host,
              !host.isEmpty else {
            return false
        }

        return true
    }
}

// MARK: - SwiftUI View

private struct LinkInputView: View {
    @State private var urlText: String
    @State private var errorMessage: String?
    @FocusState private var isTextFieldFocused: Bool

    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    init(initialURL: String, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _urlText = State(initialValue: initialURL)
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .foregroundColor(.secondary)
                    .font(.title3)

                TextField("https://", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        attemptSave()
                    }
                    .onChange(of: urlText) { _, _ in
                        // Clear error when user types
                        errorMessage = nil
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(errorMessage != nil ? Color.red.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: 0.5)
            )

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 4)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .onAppear {
            isTextFieldFocused = true
        }
    }

    private func attemptSave() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            errorMessage = "Please enter a URL"
            return
        }

        guard trimmed.count <= LinkInput.maxURLLength else {
            errorMessage = "URL exceeds maximum length of \(LinkInput.maxURLLength) characters"
            return
        }

        let lowercased = trimmed.lowercased()
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else {
            errorMessage = "URL must start with http:// or https://"
            return
        }

        guard LinkInput.isValidURL(trimmed) else {
            errorMessage = "Please enter a valid URL"
            return
        }

        onSubmit(trimmed)
    }
}
