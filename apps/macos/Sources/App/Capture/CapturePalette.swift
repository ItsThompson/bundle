import AppKit
import SwiftUI

/// Capture option type representing the three capture modes.
enum CaptureOption: Int, CaseIterable {
    case screenshot = 1
    case note = 2
    case link = 3

    var title: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .note: return "Note"
        case .link: return "Link"
        }
    }

    var icon: String {
        switch self {
        case .screenshot: return "camera.viewfinder"
        case .note: return "note.text"
        case .link: return "link"
        }
    }

    var shortcutKey: String {
        "\(rawValue)"
    }
}

/// Callback type for when a capture option is selected.
typealias CaptureOptionHandler = (CaptureOption) -> Void

/// Manages the capture palette NSPanel: a floating, non-activating panel
/// centered on the active screen with keyboard navigation.
@MainActor
final class CapturePalette {
    private var panel: NSPanel?
    private var onSelect: CaptureOptionHandler?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private let selectionState = PaletteSelectionState()

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Show the capture palette centered on the active screen.
    func show(onSelect: @escaping CaptureOptionHandler) {
        if isVisible {
            dismiss()
            return
        }

        self.onSelect = onSelect
        createPanel()
        installKeyboardMonitors()
    }

    /// Dismiss the palette without triggering any action.
    func dismiss() {
        removeKeyboardMonitors()
        panel?.orderOut(nil)
        panel = nil
        onSelect = nil
        selectionState.selectedIndex = 0
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let width: CGFloat = 260
        let height: CGFloat = 180

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

        let contentView = CapturePaletteView(
            state: selectionState,
            onSelect: { [weak self] option in
                self?.handleSelection(option)
            }
        )
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.contentView = hostingView

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    // MARK: - Keyboard Handling

    private func installKeyboardMonitors() {
        // Local monitor for when our app is focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if self.handleKeyEvent(event) {
                return nil
            }
            return event
        }

        // Global monitor for when other apps are focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
    }

    private func removeKeyboardMonitors() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Escape dismisses
        if event.keyCode == 53 { // kVK_Escape
            dismiss()
            return true
        }

        // j/k and arrow keys for navigation
        if let chars = event.charactersIgnoringModifiers {
            let maxIndex = CaptureOption.allCases.count - 1
            if chars == "j" || event.keyCode == 125 { // j or down arrow
                selectionState.selectedIndex = min(maxIndex, selectionState.selectedIndex + 1)
                return true
            }
            if chars == "k" || event.keyCode == 126 { // k or up arrow
                selectionState.selectedIndex = max(0, selectionState.selectedIndex - 1)
                return true
            }
        }

        // Number keys select directly
        if let chars = event.charactersIgnoringModifiers,
           let number = Int(chars),
           let option = CaptureOption(rawValue: number) {
            handleSelection(option)
            return true
        }

        // Enter confirms current selection
        if event.keyCode == 36 { // kVK_Return
            let option = CaptureOption.allCases[selectionState.selectedIndex]
            handleSelection(option)
            return true
        }

        return false
    }

    private func handleSelection(_ option: CaptureOption) {
        let handler = onSelect
        dismiss()
        handler?(option)
    }
}

// MARK: - Shared Selection State

@MainActor
private final class PaletteSelectionState: ObservableObject {
    @Published var selectedIndex: Int = 0
}

// MARK: - Palette SwiftUI View

private struct CapturePaletteView: View {
    @ObservedObject var state: PaletteSelectionState
    let onSelect: (CaptureOption) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(CaptureOption.allCases.enumerated()), id: \.element.rawValue) { index, option in
                CaptureOptionRow(
                    option: option,
                    isSelected: index == state.selectedIndex,
                    onSelect: { onSelect(option) }
                )
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
    }
}

private struct CaptureOptionRow: View {
    let option: CaptureOption
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: option.icon)
                    .font(.title3)
                    .frame(width: 24)

                Text(option.title)
                    .font(.body)

                Spacer()

                Text(option.shortcutKey)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
