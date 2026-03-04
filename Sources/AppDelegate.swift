import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    var hotKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = FloatingPanel()

        // Global hotkey: Control + Space to toggle
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Control + Space
            if event.modifierFlags.contains(.control) && event.keyCode == 49 {
                self?.togglePanel()
            }
        }

        // Also monitor local events so it works when our app is active
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.control) && event.keyCode == 49 {
                self?.togglePanel()
                return nil
            }
            return event
        }
    }

    func togglePanel() {
        if panel.isVisible {
            panel.close()
        } else {
            panel.show()
        }
    }
}
