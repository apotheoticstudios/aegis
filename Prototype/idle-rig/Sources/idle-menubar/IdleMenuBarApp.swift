import AppKit
import SwiftUI

/// An empty menu-bar app: roughly the smallest AegisApp could be while the panel is closed.
@main
struct IdleMenuBarApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.accessory) // no Dock icon, like the real app
    }

    var body: some Scene {
        MenuBarExtra("Aegis idle rig", systemImage: "hexagon") {
            Text("Aegis idle rig (Stage 0, #12)")
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
