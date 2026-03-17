import AppKit
import SwiftUI
import ApplicationServices
import Sparkle
import WebKit

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
    private var updateCheckTimer: Timer?
    private var feedbackPopover: NSPopover?
    private let soundPlayer = PTTSoundPlayer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedAppDelegate = self
        UserDefaults.standard.register(defaults: ["chimeEnabled": true])
        setupMainMenu()
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        setupStatusItem()
        checkForUpdateInBackground()
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

        // Hold the selected invoke key to activate the panel and voice capture; release to anchor the panel for editing.
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let invokeKeyDown = InvokeHotKey.stored().isPressed(in: event.modifierFlags)
        if invokeKeyDown && !commandKeyHeld {
            commandKeyHeld = true
            if UserDefaults.standard.bool(forKey: "chimeEnabled") {
                soundPlayer.playPress()
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
                let panel = makePanel()
                commandKeyPanel = panel
                panels.append(panel)
                panel.startCommandKeyMode()
            }
        } else if !invokeKeyDown && commandKeyHeld {
            commandKeyHeld = false
            if UserDefaults.standard.bool(forKey: "chimeEnabled") {
                soundPlayer.playRelease()
            }
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
        let versionItem = NSMenuItem(title: "HyperPointer v\(shortVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false

        let newPanelItem = NSMenuItem(title: "New Panel", action: #selector(handleStatusNewPanel), keyEquivalent: "n")
        newPanelItem.target = self

        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdatesItem.target = updaterController
        self.checkForUpdatesItem = checkForUpdatesItem

        let onboardingItem = NSMenuItem(title: "Open Onboarding", action: #selector(handleStatusOpenOnboarding), keyEquivalent: ",")
        onboardingItem.target = self

        let leaveFeedbackItem = NSMenuItem(title: "Leave Feedback", action: #selector(handleStatusLeaveFeedback), keyEquivalent: "")
        leaveFeedbackItem.target = self

        let killAllItem = NSMenuItem(title: "Kill All Tasks", action: #selector(handleStatusKillAll), keyEquivalent: "k")
        killAllItem.target = self

        let quitItem = NSMenuItem(title: "Quit HyperPointer", action: #selector(handleStatusQuit), keyEquivalent: "q")
        quitItem.target = self

        let menu = NSMenu()
        menu.addItem(versionItem)
        menu.addItem(.separator())
        menu.addItem(newPanelItem)
        menu.addItem(killAllItem)
        menu.addItem(onboardingItem)
        menu.addItem(.separator())
        menu.addItem(checkForUpdatesItem)
        menu.addItem(leaveFeedbackItem)
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

    @objc private func handleStatusLeaveFeedback() {
        openFeedbackPage()
    }

    @objc private func handleStatusKillAll() {
        for panel in panels {
            panel.searchViewModel.claudeManager?.stop()
            panel.close()
        }
        panels.removeAll()
    }

    @objc private func handleStatusQuit() {
        NSApp.terminate(nil)
    }

    private func showOnboardingIfNeeded() {
        if OnboardingViewModel.shouldResumeOnLaunch {
            showOnboarding(force: true)
            OnboardingViewModel.clearResumeOnLaunch()
            return
        }

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
            onAccessibilityStateChange: { [weak self] isGranted in
                self?.updateAccessibilityMonitoring(isGranted: isGranted)
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 618, height: 768),
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

    private func updateAccessibilityMonitoring(isGranted: Bool) {
        if isGranted {
            setupRightClickTapIfNeeded()
        } else {
            tearDownRightClickTap()
        }
    }

    private func setupRightClickTapIfNeeded() {
        guard eventTap == nil, AXIsProcessTrusted() else { return }
        setupRightClickTap()
    }

    private func tearDownRightClickTap() {
        guard let tap = eventTap else { return }
        CFMachPortInvalidate(tap)
        eventTap = nil
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

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel()
        panel.onCommandKeyDropped = { [weak self] in
            self?.commandKeyHeld = false
            self?.commandKeyPanel = nil
        }
        panel.onFeedbackShake = { [weak self] in
            self?.openFeedbackPage()
        }
        panel.onMessageSent = { [weak self] in
            if UserDefaults.standard.bool(forKey: "chimeEnabled") {
                self?.soundPlayer.playRelease()
            }
        }
        return panel
    }

    func openFeedbackPage() {
        guard let url = URL(string: "https://prickly-perfume-f62.notion.site/ebd/5ca57834b3ec456eba024dc6ac60a337") else {
            return
        }
        guard let button = statusItem?.button else {
            NSWorkspace.shared.open(url)
            return
        }

        // Keep the menu action and shake gesture on the same feedback UI path.
        if let existing = feedbackPopover, existing.isShown {
            existing.performClose(nil)
            return
        }

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 580))
        let focusDelegate = FeedbackWebViewDelegate()
        webView.navigationDelegate = focusDelegate
        webView.load(URLRequest(url: url))

        let viewController = NSViewController()
        viewController.view = webView
        objc_setAssociatedObject(viewController, &FeedbackWebViewDelegate.associatedKey, focusDelegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 480, height: 580)
        popover.contentViewController = viewController
        popover.behavior = .transient
        feedbackPopover = popover

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func createNewPanel() {
        panels.removeAll { !$0.isVisible }

        let panel = makePanel()
        panels.append(panel)
        panel.show()
    }

    func createNewPanel(at point: NSPoint) {
        // Close any existing search-mode panels (no message sent yet)
        for panel in panels where panel.isVisible && !panel.searchViewModel.isChatMode {
            panel.dismiss(restorePreviousFocus: false)
        }
        panels.removeAll { !$0.isVisible }

        let panel = makePanel()
        panels.append(panel)
        panel.show(at: point)
    }

    /// Returns true if `remote` is a newer semantic version than `local` (e.g. "0.1.2" > "0.1.1").
    private func isNewerVersion(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }

    /// Fetches the appcast in the background and shows the update badge if a newer version exists.
    /// Repeats every 10 minutes so the badge appears without waiting for Sparkle's scheduled check.
    private func checkForUpdateInBackground() {
        let check = { [weak self] in
            guard let self,
                  let feedURLString = Bundle.main.infoDictionary?["SUFeedURL"] as? String,
                  var components = URLComponents(string: feedURLString) else { return }
            // Cache-bust to bypass GitHub CDN caching
            components.queryItems = [URLQueryItem(name: "t", value: "\(Int(Date().timeIntervalSince1970))")]
            guard let feedURL = components.url else { return }
            let localVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
            var request = URLRequest(url: feedURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let data = data,
                      let xml = String(data: data, encoding: .utf8) else { return }
                if let range = xml.range(of: "(?<=<sparkle:version>)[\\d.]+(?=</sparkle:version>)", options: .regularExpression) {
                    let remoteVersion = String(xml[range])
                    if self.isNewerVersion(remoteVersion, than: localVersion) {
                        DispatchQueue.main.async {
                            self.showUpdateBadge(version: remoteVersion)
                        }
                    }
                }
            }.resume()
        }
        check()
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in check() }
    }

    private func showUpdateBadge(version: String? = nil) {
        if let version {
            checkForUpdatesItem?.title = "Update to v\(version) Available"
        } else {
            checkForUpdatesItem?.title = "Update Available"
        }

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
        let version = item.displayVersionString
        DispatchQueue.main.async { [weak self] in
            self?.showUpdateBadge(version: version)
        }
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == onboardingWindow else {
            return
        }
        onboardingWindow = nil
    }
}

private class FeedbackWebViewDelegate: NSObject, WKNavigationDelegate {
    static var associatedKey: UInt8 = 0

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Notion forms render dynamically; delay slightly to let React mount the fields.
        webView.evaluateJavaScript("""
            setTimeout(function() {
                var el = document.querySelector('input[type="text"], input[type="email"], textarea, [contenteditable="true"]');
                if (el) { el.focus(); }
            }, 600);
        """, completionHandler: nil)
    }
}
