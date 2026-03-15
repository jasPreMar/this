import AppKit
import SwiftUI
import ApplicationServices
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
    private var onboardingWindow: NSWindow?
    private var commandKeyHeld = false
    private weak var commandKeyPanel: FloatingPanel?
    private var updaterController: SPUStandardUpdaterController?
    private let onboardingSeenKey = "hasShownOnboarding"
    private var checkForUpdatesItem: NSMenuItem?
    private var updateDot: NSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedAppDelegate = self
        setupMainMenu()
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        setupStatusItem()
        setupRightClickTapIfNeeded()
        showOnboardingIfNeeded()

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

        let onboardingItem = NSMenuItem(title: "Open Onboarding", action: #selector(handleStatusOpenOnboarding), keyEquivalent: ",")
        onboardingItem.target = self

        let quitItem = NSMenuItem(title: "Quit HyperPointer", action: #selector(handleStatusQuit), keyEquivalent: "q")
        quitItem.target = self

        let menu = NSMenu()
        menu.addItem(versionItem)
        menu.addItem(.separator())
        menu.addItem(newPanelItem)
        menu.addItem(onboardingItem)
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

    @objc private func handleStatusOpenOnboarding() {
        showOnboarding(force: true)
    }

    @objc private func handleStatusQuit() {
        NSApp.terminate(nil)
    }

    private func showOnboardingIfNeeded() {
        if !UserDefaults.standard.bool(forKey: onboardingSeenKey) {
            showOnboarding()
        }
    }

    private func showOnboarding(force: Bool = false) {
        if let onboardingWindow {
            onboardingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        if !force && UserDefaults.standard.bool(forKey: onboardingSeenKey) {
            return
        }

        let viewModel = OnboardingViewModel(
            onFinish: { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(true, forKey: self.onboardingSeenKey)
                self.closeOnboarding()
            },
            onAccessibilityGranted: { [weak self] in
                self?.setupRightClickTapIfNeeded()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "HyperPointer Setup"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(rootView: OnboardingView(viewModel: viewModel))
        window.delegate = self

        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeOnboarding() {
        onboardingWindow?.orderOut(nil)
        onboardingWindow = nil
    }

    private func setupRightClickTapIfNeeded() {
        guard eventTap == nil, AXIsProcessTrusted() else { return }
        setupRightClickTap()
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

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == onboardingWindow else {
            return
        }
        onboardingWindow = nil
        UserDefaults.standard.set(true, forKey: onboardingSeenKey)
    }
}
