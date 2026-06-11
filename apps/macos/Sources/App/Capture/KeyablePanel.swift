import AppKit

/// NSPanel subclass that can become key window even with `.nonactivatingPanel` style.
/// Standard macOS pattern for menubar (.accessory) apps that need text input
/// in floating panels without activating the app or showing a Dock icon.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// NSWindow subclass that can become key with `.borderless` style.
/// Used for full-screen overlays (screenshot region selection) that need
/// keyboard events (Escape to cancel).
final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
