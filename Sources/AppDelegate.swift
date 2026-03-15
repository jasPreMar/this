import AppKit
import SwiftUI
import ApplicationServices
import AVFoundation
import Speech
import Sparkle

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
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var statusItem: NSStatusItem?
    private var commandKeyHeld = false
    private weak var commandKeyPanel: FloatingPanel?
    private var updaterController: SPUStandardUpdaterController?
    private var checkForUpdatesItem: NSMenuItem?
    private var updateDot: NSView?
    private var updateCheckTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedAppDelegate = self
        setupMainMenu()
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        setupStatusItem()
        checkForUpdateInBackground()
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

        // Hold ⌘ to activate panel; release before sending = dismiss, release after = keep
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let commandDown = event.modifierFlags.contains(.command)
        if commandDown && !commandKeyHeld {
            commandKeyHeld = true

            // Don't enter command-key mode when the user is typing in a chat panel —
            // let standard Cmd shortcuts (⌘A, ⌘C, ⌘Z, etc.) reach the text field.
            if panels.first(where: { $0.isVisible && $0.searchViewModel.isChatMode && $0.isKeyWindow }) != nil {
                return
            }

            // Reuse an existing visible non-chat panel if one exists
            if let existing = panels.first(where: {
                $0.isVisible && !$0.searchViewModel.isChatMode
            }) {
                commandKeyPanel = existing
                existing.isCommandKeyHeld = true
                existing.restartCommandKeyMode()
            } else {
                panels.removeAll { !$0.isVisible }
                let panel = FloatingPanel()
                commandKeyPanel = panel
                panels.append(panel)
                panel.startCommandKeyMode()
            }
        } else if !commandDown && commandKeyHeld {
            commandKeyHeld = false
            if let panel = commandKeyPanel {
                panel.isCommandKeyHeld = false
                panel.endCommandKeyMode()
            }
            commandKeyPanel = nil
        }
    }

    // MARK: - Main Menu (key equivalents for text editing)

    /// Registers standard Edit menu key equivalents so that Cmd+A, Cmd+C, Cmd+V, etc.
    /// are dispatched to the first responder (NSTextView) even though we have no visible menu bar.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "HyperPointer")
            button.imagePosition = .imageOnly
            button.toolTip = "HyperPointer"
        }

        let bundle = Bundle.main
        let shortVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let versionItem = NSMenuItem(title: "HyperPointer v\(shortVersion).\(buildNumber)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false

        let newPanelItem = NSMenuItem(title: "New Panel", action: #selector(handleStatusNewPanel), keyEquivalent: "n")
        newPanelItem.target = self

        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdatesItem.target = updaterController
        self.checkForUpdatesItem = checkForUpdatesItem

        let quitItem = NSMenuItem(title: "Quit HyperPointer", action: #selector(handleStatusQuit), keyEquivalent: "q")
        quitItem.target = self

        let menu = NSMenu()
        menu.addItem(versionItem)
        menu.addItem(.separator())
        menu.addItem(newPanelItem)
        menu.addItem(.separator())
        menu.addItem(checkForUpdatesItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    @objc private func handleStatusNewPanel() {
        createNewPanel()
    }

    @objc private func handleStatusQuit() {
        NSApp.terminate(nil)
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

        // 3. Voice input permissions — required for Shift-to-dictate.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard granted else { return }
            SFSpeechRecognizer.requestAuthorization { _ in }
        }

        // 4. Apple Events (Automation) — required when Claude runs `osascript` to control
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
            panel.dismiss(restorePreviousFocus: false)
        }
        panels.removeAll { !$0.isVisible }

        let panel = FloatingPanel()
        panels.append(panel)
        panel.show(at: point)
    }

    /// Fetches the appcast in the background and shows the update badge if a newer version exists.
    /// Repeats every hour so the badge appears without waiting for Sparkle's scheduled check.
    private func checkForUpdateInBackground() {
        let check = { [weak self] in
            guard let feedURLString = Bundle.main.infoDictionary?["SUFeedURL"] as? String,
                  let feedURL = URL(string: feedURLString) else { return }
            let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
            URLSession.shared.dataTask(with: feedURL) { data, _, _ in
                guard let data = data,
                      let xml = String(data: data, encoding: .utf8) else { return }
                // Parse the latest sparkle:version (build number) from the appcast
                if let range = xml.range(of: "(?<=<sparkle:version>)\\d+(?=</sparkle:version>)", options: .regularExpression),
                   let remoteBuild = Int(xml[range]),
                   let localBuild = Int(currentBuild),
                   remoteBuild > localBuild {
                    DispatchQueue.main.async {
                        self?.showUpdateBadge()
                    }
                }
            }.resume()
        }
        check()
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in check() }
    }

    private func showUpdateBadge() {
        checkForUpdatesItem?.title = "Update Available"

        guard let button = statusItem?.button, updateDot == nil else { return }
        let dotSize: CGFloat = 6
        let dot = NSView(frame: NSRect(
            x: button.bounds.maxX - dotSize - 3,
            y: button.bounds.maxY - dotSize - 3,
            width: dotSize,
            height: dotSize
        ))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = dotSize / 2
        button.addSubview(dot)
        updateDot = dot
    }
}

// MARK: - SPUUpdaterDelegate

extension AppDelegate: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        DispatchQueue.main.async { [weak self] in
            self?.showUpdateBadge()
        }
    }
}
