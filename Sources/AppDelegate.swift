import AppKit
import SwiftUI
import ApplicationServices

// Global reference for CGEventTap callback (C function pointers can't capture context)
private weak var sharedAppDelegate: AppDelegate?

// CGEventTap callback — must be a free function (no closures allowed)
private func rightClickCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Re-enable if system disabled the tap due to timeout
    if type == .tapDisabledByTimeout {
        if let tap = sharedAppDelegate?.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .rightMouseDown else {
        return Unmanaged.passRetained(event)
    }

    // Only activate on Command + right click; let plain right clicks through
    guard event.flags.contains(.maskCommand) else {
        return Unmanaged.passRetained(event)
    }

    // Convert CG coordinates (top-left origin) to NS coordinates (bottom-left origin)
    let cgLocation = event.location
    if let screen = NSScreen.main {
        let nsPoint = NSPoint(
            x: cgLocation.x,
            y: screen.frame.height - cgLocation.y
        )
        DispatchQueue.main.async {
            sharedAppDelegate?.createNewPanel(at: nsPoint)
        }
    }

    // Return nil to suppress the native context menu
    return nil
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var panels: [FloatingPanel] = []
    var hotKeyMonitor: Any?
    fileprivate var eventTap: CFMachPort?

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedAppDelegate = self
        requestInitialPermissions()
        setupRightClickTap()

        // Global hotkey: Control + Space to create new panel
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.control) && event.keyCode == 49 {
                self?.createNewPanel()
            }
        }

        // Also monitor local events so it works when our app is active
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.control) && event.keyCode == 49 {
                self?.createNewPanel()
                return nil
            }
            return event
        }
    }

    // MARK: - Permission Setup

    /// Pre-request all permissions HyperPointer needs so macOS dialogs appear upfront
    /// rather than surprising the user mid-task when Claude runs a shell command.
    private func requestInitialPermissions() {
        // 1. Accessibility — required for the CGEventTap and Accessibility API.
        //    If not yet granted, this prompts the user and opens System Settings.
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        // 2. Screen Recording — required for window screenshots.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        // 3. Apple Events (Automation) — required when Claude runs `osascript` to control
        //    other apps. Pre-warm all foreground apps currently running, and observe any
        //    app that launches later. TCC only shows a dialog once per app pair; after
        //    Allow is clicked it's remembered forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.preWarmAllRunningApps()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
    }

    private func preWarmAllRunningApps() {
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
            preWarmAppleEventsPermission(for: bundleID)
        }
    }

    @objc private func appDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular,
              let bundleID = app.bundleIdentifier,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        preWarmAppleEventsPermission(for: bundleID)
    }

    /// Triggers the macOS Automation permission dialog for `bundleID` if not already granted.
    /// Uses `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: true`.
    /// The target app does not need to be running — TCC grants permissions by bundle ID pair.
    private func preWarmAppleEventsPermission(for bundleID: String) {
        // typeApplicationBundleID = 'bund' (OSType 0x62756E64)
        let bundDescType: OSType = 0x62756E64
        bundleID.withCString { cStr in
            var targetDesc = AEDesc()
            guard AECreateDesc(bundDescType, cStr, bundleID.utf8.count, &targetDesc) == noErr else { return }
            // typeWildCard = '****' — request permission for any event class/ID
            AEDeterminePermissionToAutomateTarget(&targetDesc, OSType(0x2A2A2A2A), OSType(0x2A2A2A2A), true)
            AEDisposeDesc(&targetDesc)
        }
    }

    private func setupRightClickTap() {
        let eventMask: CGEventMask = (1 << CGEventType.rightMouseDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: rightClickCallback,
            userInfo: nil
        ) else {
            print("Failed to create event tap — ensure Accessibility permissions are granted.")
            return
        }

        eventTap = tap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func createNewPanel() {
        panels.removeAll { !$0.isVisible }

        let panel = FloatingPanel()
        panels.append(panel)
        panel.show()
    }

    func createNewPanel(at point: NSPoint) {
        // Close any existing search-mode panels (no message sent yet)
        for panel in panels where panel.isVisible && !panel.searchViewModel.isChatMode {
            panel.close()
        }
        panels.removeAll { !$0.isVisible }

        let panel = FloatingPanel()
        panels.append(panel)
        panel.show(at: point)
    }
}
