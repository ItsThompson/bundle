import SwiftUI

@main
struct BundleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Bundle", systemImage: "square.grid.2x2") {
            Button("Capture Artifact") {
                print("[Bundle] Capture Artifact selected")
            }
            .keyboardShortcut("1")

            Button("Show Artifacts") {
                appDelegate.showRetrievalPanel()
            }
            .keyboardShortcut("2")

            Divider()

            Button("Settings") {
                appDelegate.openSettings()
            }
            .keyboardShortcut(",")

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
