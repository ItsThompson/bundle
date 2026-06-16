import AppKit
import SwiftUI

/// Raw output of the note editor.
/// Renamed from NoteCaptureResult to avoid confusion with the unified Models/CaptureResult enum.
struct NoteCaptureOutput {
    let filePath: URL
    let artifactId: String
    let content: String
    let createdAt: Date
}

/// Maximum note length enforced client-side.
private let maxNoteLength = 50_000

/// Manages the note editor NSPanel: a floating, non-activating panel
/// with a minimal markdown text area.
@MainActor
final class NoteEditor {
    private var panel: NSPanel?
    private var onSave: ((NoteCaptureOutput) -> Void)?
    private var localMonitor: Any?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Show the note editor panel centered on the active screen.
    /// Calls onSave with the capture result when the user saves (Cmd+Enter).
    func show(onSave: @escaping (NoteCaptureOutput) -> Void) {
        if isVisible {
            dismiss()
            return
        }

        self.onSave = onSave
        createPanel()
    }

    /// Dismiss the editor without saving.
    func dismiss() {
        removeKeyboardMonitor()
        panel?.orderOut(nil)
        panel = nil
        onSave = nil
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let width: CGFloat = 480
        let height: CGFloat = 320

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

        let contentView = NoteEditorView(
            onSave: { [weak self] text in
                self?.handleSave(text: text)
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
            if event.keyCode == 53 {
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

    // MARK: - Save Logic

    private func handleSave(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Do not save empty notes
        guard !trimmed.isEmpty else {
            dismiss()
            return
        }

        // Enforce max length
        let content = String(trimmed.prefix(maxNoteLength))

        guard let result = saveNoteFile(content: content) else {
            dismiss()
            return
        }

        let handler = onSave
        dismiss()
        handler?(result)
    }

    // MARK: - File Save

    private func saveNoteFile(content: String) -> NoteCaptureOutput? {
        let now = Date()
        let artifactId = UUID().uuidString.lowercased()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd"
        let dateStr = dateFormatter.string(from: now)

        let baseDir = CaptureCoordinator.artifactsDirectory.appendingPathComponent(dateStr)

        do {
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        } catch {
            print("[Bundle] Failed to create artifacts directory: \(error)")
            return nil
        }

        let filePath = baseDir.appendingPathComponent("\(artifactId).md")

        do {
            try content.write(to: filePath, atomically: true, encoding: .utf8)
        } catch {
            print("[Bundle] Failed to write note file: \(error)")
            return nil
        }

        return NoteCaptureOutput(
            filePath: filePath,
            artifactId: artifactId,
            content: content,
            createdAt: now
        )
    }

}

// MARK: - Note Editor SwiftUI View

private struct NoteEditorView: View {
    @State private var text: String = ""
    @FocusState private var isFocused: Bool
    let onSave: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header with hint
            HStack {
                Text("Note")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundColor(.primary)
                Spacer()
                Text("⌘↩ save · esc cancel")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Text editor: minimal, monospace, no toolbar
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .onChange(of: text) { _, newValue in
                    // Enforce max length client-side
                    if newValue.count > maxNoteLength {
                        text = String(newValue.prefix(maxNoteLength))
                    }
                }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .onAppear {
            isFocused = true
        }
        .onKeyPress(keys: [.return], phases: .down) { keyPress in
            // Cmd+Enter saves
            if keyPress.modifiers.contains(.command) {
                onSave(text)
                return .handled
            }
            return .ignored
        }
    }
}
