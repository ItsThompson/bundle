import Carbon.HIToolbox
import Cocoa
import Combine

/// Represents a key combination (modifier flags + key code).
struct KeyCombo: Equatable, Codable {
    let keyCode: UInt16
    let modifiers: UInt

    /// Human-readable representation (e.g., "⌘⇧B").
    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt(NSEvent.ModifierFlags.control.rawValue) != 0 { parts.append("⌃") }
        if modifiers & UInt(NSEvent.ModifierFlags.option.rawValue) != 0 { parts.append("⌥") }
        if modifiers & UInt(NSEvent.ModifierFlags.shift.rawValue) != 0 { parts.append("⇧") }
        if modifiers & UInt(NSEvent.ModifierFlags.command.rawValue) != 0 { parts.append("⌘") }

        if let keyName = Self.keyCodeToString(keyCode) {
            parts.append(keyName)
        }

        return parts.joined()
    }

    /// Default hotkey: Cmd+Shift+B.
    static let defaultCombo = KeyCombo(
        keyCode: UInt16(kVK_ANSI_B),
        modifiers: UInt(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue)
    )

    /// Checks if this combo conflicts with common system hotkeys.
    var potentialConflicts: [String] {
        var conflicts: [String] = []

        let cmd = UInt(NSEvent.ModifierFlags.command.rawValue)
        let cmdShift = UInt(NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue)

        // Common macOS system shortcuts
        if modifiers == cmd {
            switch Int(keyCode) {
            case kVK_ANSI_C: conflicts.append("Copy (⌘C)")
            case kVK_ANSI_V: conflicts.append("Paste (⌘V)")
            case kVK_ANSI_X: conflicts.append("Cut (⌘X)")
            case kVK_ANSI_Z: conflicts.append("Undo (⌘Z)")
            case kVK_ANSI_A: conflicts.append("Select All (⌘A)")
            case kVK_ANSI_Q: conflicts.append("Quit (⌘Q)")
            case kVK_ANSI_W: conflicts.append("Close Window (⌘W)")
            case kVK_Tab: conflicts.append("Switch App (⌘Tab)")
            case kVK_Space: conflicts.append("Spotlight (⌘Space)")
            default: break
            }
        }

        if modifiers == cmdShift {
            switch Int(keyCode) {
            case kVK_ANSI_3: conflicts.append("Screenshot Full (⌘⇧3)")
            case kVK_ANSI_4: conflicts.append("Screenshot Area (⌘⇧4)")
            case kVK_ANSI_5: conflicts.append("Screenshot Options (⌘⇧5)")
            case kVK_ANSI_Z: conflicts.append("Redo (⌘⇧Z)")
            default: break
            }
        }

        return conflicts
    }

    // MARK: - Key Code to String Mapping

    private static func keyCodeToString(_ keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_Space: return "Space"
        case kVK_Tab: return "Tab"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Fwd Delete"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return nil
        }
    }

    // MARK: - UserDefaults Persistence

    private static let userDefaultsKey = "com.bundle.hotkey"

    /// Load saved hotkey from UserDefaults, or return default.
    static func loadFromDefaults() -> KeyCombo {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) else {
            return .defaultCombo
        }
        return combo
    }

    /// Save hotkey to UserDefaults.
    func saveToDefaults() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}

/// Manages global hotkey registration via CGEvent tap.
/// Provides recording mode for capturing new key combinations.
@MainActor
final class HotkeyManager: ObservableObject {
    @Published private(set) var currentCombo: KeyCombo
    @Published private(set) var isRecording = false

    /// Non-isolated copy of the combo for the C callback to compare against.
    /// Updated whenever `currentCombo` changes.
    nonisolated(unsafe) private var _callbackCombo: KeyCombo = .defaultCombo

    /// Non-isolated reference to the event tap for re-enabling on timeout.
    nonisolated(unsafe) fileprivate var _callbackEventTap: CFMachPort?

    /// Called when the hotkey is triggered.
    var onHotkeyPressed: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var localMonitor: Any?

    /// Callback invoked during recording mode when a key combo is captured.
    private var recordingCompletion: ((KeyCombo) -> Void)?

    init() {
        self.currentCombo = KeyCombo.loadFromDefaults()
        self._callbackCombo = self.currentCombo
    }

    /// Register the global hotkey event tap. Call once at app launch.
    func register() {
        unregister()

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // The callback needs to reference self, which we pass via userInfo
        let unmanagedSelf = Unmanaged.passUnretained(self)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: unmanagedSelf.toOpaque()
        ) else {
            print("[Bundle] Failed to create CGEvent tap. Accessibility permissions required.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self._callbackEventTap = tap
        self.runLoopSource = source
    }

    /// Unregister the current event tap.
    func unregister() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        _callbackEventTap = nil
        runLoopSource = nil
    }

    /// Update the hotkey combination: saves to UserDefaults and re-registers the event tap.
    func updateHotkey(_ combo: KeyCombo) {
        currentCombo = combo
        _callbackCombo = combo
        combo.saveToDefaults()
        register()
    }

    // MARK: - Recording Mode

    /// Enter recording mode: captures the next key combo via local event monitor.
    /// Disables the global event tap so the current hotkey doesn't fire during recording.
    func startRecording(completion: @escaping (KeyCombo) -> Void) {
        isRecording = true
        recordingCompletion = completion

        // Disable global hotkey during recording to avoid triggering capture palette
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Escape cancels recording
            if event.keyCode == UInt16(kVK_Escape) && modifiers.isEmpty {
                Task { @MainActor in
                    self.stopRecording()
                }
                return nil
            }

            // Require at least one modifier key
            guard !modifiers.isEmpty else { return nil }

            // Ignore standalone modifier presses (e.g., just Cmd without another key)
            let modifierOnlyKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
            guard !modifierOnlyKeyCodes.contains(event.keyCode) else { return nil }

            let combo = KeyCombo(keyCode: event.keyCode, modifiers: modifiers.rawValue)

            Task { @MainActor in
                self.recordingCompletion?(combo)
                self.stopRecording()
            }

            return nil // Consume the event
        }
    }

    /// Exit recording mode without changing the hotkey.
    func stopRecording() {
        isRecording = false
        recordingCompletion = nil
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }

        // Re-enable global hotkey after recording ends
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // MARK: - Event Tap Callback

    /// Called by the CGEvent tap when a key event fires globally.
    /// Must be nonisolated so the C callback can invoke it synchronously.
    nonisolated func handleGlobalKeyEvent(_ event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Build modifier mask matching our KeyCombo representation
        var modifiers: UInt = 0
        if flags.contains(.maskCommand) { modifiers |= UInt(NSEvent.ModifierFlags.command.rawValue) }
        if flags.contains(.maskShift) { modifiers |= UInt(NSEvent.ModifierFlags.shift.rawValue) }
        if flags.contains(.maskAlternate) { modifiers |= UInt(NSEvent.ModifierFlags.option.rawValue) }
        if flags.contains(.maskControl) { modifiers |= UInt(NSEvent.ModifierFlags.control.rawValue) }

        let pressed = KeyCombo(keyCode: keyCode, modifiers: modifiers)
        if pressed == _callbackCombo {
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyPressed?()
            }
            return true // Consume the event
        }
        return false
    }
}

// MARK: - CGEvent Tap Callback (C function)

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Handle tap disabled events (system may disable the tap)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            // Re-enable the tap
            if let tap = manager._callbackEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown, let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

    if manager.handleGlobalKeyEvent(event) {
        return nil // Consume the event
    }

    return Unmanaged.passRetained(event)
}
