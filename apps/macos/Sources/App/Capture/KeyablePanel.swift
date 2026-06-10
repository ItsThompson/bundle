import AppKit

/// NSPanel subclass that can become key window even with `.nonactivatingPanel` style.
/// Standard macOS pattern for menubar (.accessory) apps that need text input
/// in floating panels without activating the app or showing a Dock icon.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
