import AppKit
import CoreGraphics

extension AppDelegate {
    /// Prompt for Accessibility and Input Monitoring permissions if not already granted.
    func requestAccessibilityIfNeeded() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        if !CGPreflightPostEventAccess() { CGRequestPostEventAccess() }
    }

    /// Prompt for Screen Recording permission if not already granted.
    func requestScreenCaptureIfNeeded() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }
}
