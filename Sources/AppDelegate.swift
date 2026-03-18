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

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private enum CommandMenuPresentationSource {
        case statusItem
        case invokeHotKey
    }

    var panels: [FloatingPanel] = []
    @Published private(set) var taskRecords: [TaskSessionRecord] = []
    var hotKeyMonitor: Any?
    private var localHotKeyMonitor: Any?
    fileprivate var eventTap: CFMachPort?
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var statusItem: NSStatusItem?
    private var legacyStatusMenu: NSMenu?
    private var commandMenuPanel: CommandMenuPanel?
    private var commandMenuGlobalMouseMonitor: Any?
    private var commandMenuLocalMouseMonitor: Any?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var commandKeyHeld = false
    private weak var commandKeyPanel: FloatingPanel?
    private var updaterController: SPUStandardUpdaterController?
    private let onboardingSeenKey = "hasShownOnboarding"
    private var checkForUpdatesItem: NSMenuItem?
    private var updateDot: NSView?
    private var updateCheckTimer: Timer?
    private var feedbackPopover: NSPopover?
    private let soundPlayer = PTTSoundPlayer()
    private var taskRecordLookup: [ObjectIdentifier: TaskSessionRecord] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedAppDelegate = self
        AppSettings.registerDefaults()
        setupMainMenu()
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        setupStatusItem()
        checkForUpdateInBackground()
        setupRightClickTapIfNeeded()
        loadPersistedChatSessions()
        showOnboardingIfNeeded()

        // Global hotkey: selected invoke key + Space toggles the task overlay.
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyDown(event)
        }

        // Also monitor local events so it works when our app is active.
        localHotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleLocalKeyDown(event) ?? event
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
        let modifierFlags = event.modifierFlags
        let invokeKeyDown = InvokeHotKey.stored().isPressed(in: modifierFlags)
        if commandMenuPanel?.isVisible == true {
            if !invokeKeyDown {
                commandKeyHeld = false
                commandKeyPanel = nil
            }
            return
        }

        if invokeKeyDown && !commandKeyHeld {
            commandKeyHeld = true

            // Reuse an existing visible non-chat panel if one exists
            if let existing = panels.first(where: {
                $0.isVisible && !$0.searchViewModel.isChatMode
            }) {
                commandKeyPanel = existing
                existing.isCommandKeyHeld = true
                existing.restartCommandKeyMode(with: modifierFlags)
            } else {
                panels.removeAll { !$0.isVisible && !$0.preservesTaskHistory }
                let panel = makePanel()
                commandKeyPanel = panel
                panels.append(panel)
                panel.startCommandKeyMode(with: modifierFlags)
            }
        } else if invokeKeyDown && commandKeyHeld {
            commandKeyPanel?.updateModifierFlags(modifierFlags)
        } else if !invokeKeyDown && commandKeyHeld {
            commandKeyHeld = false
            if let panel = commandKeyPanel {
                panel.isCommandKeyHeld = false
                panel.updateModifierFlags(modifierFlags)
                panel.endCommandKeyMode()
            }
            commandKeyPanel = nil
        }
    }

    private func handleGlobalKeyDown(_ event: NSEvent) {
        guard event.keyCode == 49,
              InvokeHotKey.stored().isPressed(in: event.modifierFlags) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.toggleCommandMenu(from: .invokeHotKey)
        }
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 49,
              InvokeHotKey.stored().isPressed(in: event.modifierFlags) else {
            return event
        }

        toggleCommandMenu(from: .invokeHotKey)
        return nil
    }

    // MARK: - Main Menu (key equivalents for text editing)

    /// Registers the standard macOS menu structure so window shortcuts continue
    /// to flow through the responder chain when HyperPointer opens a normal app window.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "HyperPointer"

        let appMenuItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: appName)
        appMenuItem.submenu = appMenu

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(handleStatusOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        appMenu.addItem(NSMenuItem(title: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))

        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
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

        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu

        let fullScreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)

        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "HyperPointer")
            button.imagePosition = .imageOnly
            button.toolTip = "HyperPointer"
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let bundle = Bundle.main
        let shortVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = NSMenuItem(title: "HyperPointer v\(shortVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false

        let newPanelItem = NSMenuItem(title: "New Panel", action: #selector(handleStatusNewPanel), keyEquivalent: "n")
        newPanelItem.target = self

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(handleStatusOpenSettings), keyEquivalent: ",")
        settingsItem.target = self

        let checkForUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        checkForUpdatesItem.target = updaterController
        self.checkForUpdatesItem = checkForUpdatesItem

        let onboardingItem = NSMenuItem(title: "Open Onboarding", action: #selector(handleStatusOpenOnboarding), keyEquivalent: "")
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
        menu.addItem(settingsItem)
        menu.addItem(killAllItem)
        menu.addItem(onboardingItem)
        menu.addItem(.separator())
        menu.addItem(checkForUpdatesItem)
        menu.addItem(leaveFeedbackItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        legacyStatusMenu = menu
        self.statusItem = statusItem
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggleCommandMenu(from: .statusItem)
            return
        }

        switch event.type {
        case .rightMouseUp:
            closeCommandMenu()
            if let legacyStatusMenu, let button = statusItem?.button {
                legacyStatusMenu.popUp(
                    positioning: nil,
                    at: NSPoint(x: 0, y: button.bounds.height + 6),
                    in: button
                )
            }
        default:
            toggleCommandMenu(from: .statusItem)
        }
    }

    @objc private func handleStatusNewPanel() {
        createNewPanel()
    }

    @objc private func handleStatusOpenSettings() {
        showSettings()
    }

    @objc private func handleStatusOpenOnboarding() {
        showOnboarding(force: true)
    }

    @objc private func handleStatusLeaveFeedback() {
        openFeedbackPage()
    }

    @objc private func handleStatusKillAll() {
        closeCommandMenu()
        for panel in panels {
            panel.saveChatSession()
            panel.searchViewModel.claudeManager?.stop()
            panel.destroyPersistentTaskWindow()
        }
        panels.removeAll()
        // Reload persisted sessions so they remain visible
        taskRecords.removeAll()
        taskRecordLookup.removeAll()
        loadPersistedChatSessions()
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
            refreshApplicationPresentation()
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
        refreshApplicationPresentation()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeOnboarding() {
        onboardingWindow?.orderOut(nil)
        onboardingWindow = nil
        refreshApplicationPresentation()
    }

    func openSettingsFromCommandMenu() {
        closeCommandMenu()
        showSettings()
    }

    private func showSettings() {
        if let settingsWindow {
            refreshApplicationPresentation()
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "HyperPointer Settings"
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsView(
                onAccessibilityStateChange: { [weak self] isGranted in
                    self?.updateAccessibilityMonitoring(isGranted: isGranted)
                },
                onCheckForUpdates: { [weak self] in
                    self?.checkForUpdates()
                },
                onLeaveFeedback: { [weak self] in
                    self?.openFeedbackPage()
                }
            )
        )
        window.delegate = self

        settingsWindow = window
        refreshApplicationPresentation()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func toggleCommandMenu(from source: CommandMenuPresentationSource) {
        if commandMenuPanel?.isVisible == true {
            closeCommandMenu()
        } else {
            showCommandMenu(from: source)
        }
    }

    private func showCommandMenu(from source: CommandMenuPresentationSource) {
        if commandMenuPanel == nil {
            let panel = CommandMenuPanel(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.onEscape = { [weak self] in
                self?.closeCommandMenu()
            }
            commandMenuPanel = panel
        }

        if source == .invokeHotKey {
            dismissCommandKeyPanelForCommandMenu()
        }
        commandMenuPanel?.contentView = NSHostingView(rootView: CommandMenuView(appDelegate: self))
        positionCommandMenu(for: source)
        installCommandMenuEventMonitors()
        commandMenuPanel?.makeKeyAndOrderFront(nil)
        statusItem?.button?.highlight(source == .statusItem)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionCommandMenu(for source: CommandMenuPresentationSource) {
        guard let panel = commandMenuPanel,
              let origin = commandMenuOrigin(for: source) else { return }

        panel.setRestingOrigin(origin, snapBackEnabled: source == .invokeHotKey)
        panel.setFrameOrigin(origin)
    }

    private func commandMenuOrigin(for source: CommandMenuPresentationSource) -> NSPoint? {
        guard let panel = commandMenuPanel else { return nil }

        switch source {
        case .statusItem:
            guard let statusButton = statusItem?.button,
                  let buttonWindow = statusButton.window else { return nil }

            let buttonFrame = buttonWindow.frame
            let targetScreen = NSScreen.screens.first(where: { $0.frame.intersects(buttonFrame) }) ?? NSScreen.main
            let visibleFrame = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

            var origin = NSPoint(
                x: buttonFrame.midX - panel.frame.width / 2,
                y: buttonFrame.minY - panel.frame.height - 8
            )
            origin.x = max(visibleFrame.minX + 8, min(origin.x, visibleFrame.maxX - panel.frame.width - 8))
            origin.y = max(visibleFrame.minY + 8, min(origin.y, visibleFrame.maxY - panel.frame.height - 8))
            return origin

        case .invokeHotKey:
            let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
            let visibleFrame = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let topInset: CGFloat = 88
            let horizontalInset: CGFloat = 8

            let unclampedX = visibleFrame.midX - panel.frame.width / 2
            let unclampedY = visibleFrame.maxY - panel.frame.height - topInset
            return NSPoint(
                x: max(visibleFrame.minX + horizontalInset, min(unclampedX, visibleFrame.maxX - panel.frame.width - horizontalInset)),
                y: max(visibleFrame.minY + horizontalInset, min(unclampedY, visibleFrame.maxY - panel.frame.height - horizontalInset))
            )
        }
    }

    private func dismissCommandKeyPanelForCommandMenu() {
        commandKeyHeld = false

        if let panel = commandKeyPanel {
            panel.isCommandKeyHeld = false
            panel.dismiss(restorePreviousFocus: false)
            commandKeyPanel = nil
        }
    }

    private func installCommandMenuEventMonitors() {
        tearDownCommandMenuEventMonitors()

        commandMenuGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismissCommandMenuIfNeeded(at: NSEvent.mouseLocation)
        }

        commandMenuLocalMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            self.dismissCommandMenuIfNeeded(at: screenPoint)
            return event
        }
    }

    private func tearDownCommandMenuEventMonitors() {
        if let commandMenuGlobalMouseMonitor {
            NSEvent.removeMonitor(commandMenuGlobalMouseMonitor)
            self.commandMenuGlobalMouseMonitor = nil
        }
        if let commandMenuLocalMouseMonitor {
            NSEvent.removeMonitor(commandMenuLocalMouseMonitor)
            self.commandMenuLocalMouseMonitor = nil
        }
    }

    private func dismissCommandMenuIfNeeded(at screenPoint: NSPoint) {
        guard let panel = commandMenuPanel, panel.isVisible else { return }

        if panel.frame.contains(screenPoint) {
            return
        }

        if let statusButtonRect = statusButtonScreenRect(), statusButtonRect.contains(screenPoint) {
            return
        }

        closeCommandMenu()
    }

    private func statusButtonScreenRect() -> NSRect? {
        guard let buttonWindow = statusItem?.button?.window else { return nil }
        return buttonWindow.frame
    }

    private func refreshApplicationPresentation() {
        let targetPolicy: NSApplication.ActivationPolicy = onboardingWindow != nil || settingsWindow != nil ? .regular : .accessory
        if NSApp.activationPolicy() != targetPolicy {
            NSApp.setActivationPolicy(targetPolicy)
        }
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
                self?.soundPlayer.playPress()
            }
        }
        panel.onStreamingComplete = { [weak self] in
            if UserDefaults.standard.bool(forKey: "chimeEnabled") {
                self?.soundPlayer.playRelease()
            }
        }
        panel.onPersistentTaskStarted = { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            self.registerTaskRecord(for: panel)
        }
        panel.onTaskStateChanged = { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            self.syncTaskRecord(for: panel)
        }
        panel.onPanelDestroyed = { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            self.removePanel(panel)
        }
        return panel
    }

    func launchTaskFromCommandMenu(query: String) {
        let panel = makePanel()
        panels.append(panel)
        panel.startTaskFromMenu(query: query)
    }

    func openTaskRecord(_ record: TaskSessionRecord) {
        if let panel = record.panel {
            panel.reopenPersistentTaskWindow()
            return
        }

        // Reopen a persisted session that has no live panel
        guard let persistedId = record.persistedSessionId else { return }
        let sessions = ChatSessionStore.shared.loadAll()
        guard let session = sessions.first(where: { $0.id == persistedId }) else { return }

        let panel = makePanel()
        panels.append(panel)
        panel.persistedSessionId = persistedId

        // Restore working directory
        let workingDirectoryURL: URL?
        if let path = session.workingDirectoryPath {
            workingDirectoryURL = URL(fileURLWithPath: path)
        } else {
            workingDirectoryURL = nil
        }

        // Populate chat history from persisted messages
        panel.searchViewModel.chatHistory = session.messages.map {
            (role: $0.role, text: $0.text, events: [] as [StreamEvent])
        }
        panel.searchViewModel.currentSessionId = session.sessionId
        panel.searchViewModel.currentSessionWorkingDirectoryURL = workingDirectoryURL
        panel.searchViewModel.isChatMode = true

        // Transition to terminal mode to show the restored chat
        panel.transitionToTerminal(
            message: "",
            workingDirectoryURL: workingDirectoryURL,
            centerWindow: true,
            restoreOnly: true
        )

        // Re-associate the record with the live panel
        record.panel = panel
        let key = ObjectIdentifier(panel)
        taskRecordLookup[key] = record
        record.sync(from: panel)
    }

    func stopTaskRecord(_ record: TaskSessionRecord) {
        record.panel?.searchViewModel.claudeManager?.stop()
    }

    func deleteTaskRecord(_ record: TaskSessionRecord) {
        // Delete persisted session from disk
        if let persistedId = record.persistedSessionId {
            ChatSessionStore.shared.delete(id: persistedId)
        } else if let panel = record.panel, let persistedId = panel.persistedSessionId {
            ChatSessionStore.shared.delete(id: persistedId)
        }

        guard let panel = record.panel else {
            taskRecords.removeAll { $0.id == record.id }
            return
        }

        panel.searchViewModel.claudeManager?.stop()
        panel.destroyPersistentTaskWindow()
        removePanel(panel)
    }

    func closeCommandMenu() {
        tearDownCommandMenuEventMonitors()
        statusItem?.button?.highlight(false)
        commandMenuPanel?.orderOut(nil)
    }

    private func registerTaskRecord(for panel: FloatingPanel) {
        let key = ObjectIdentifier(panel)
        if let existing = taskRecordLookup[key] {
            existing.sync(from: panel)
            sortTaskRecords()
            return
        }

        let record = TaskSessionRecord(panel: panel)
        record.persistedSessionId = panel.persistedSessionId
        taskRecordLookup[key] = record
        taskRecords.append(record)
        sortTaskRecords()
    }

    private func syncTaskRecord(for panel: FloatingPanel) {
        guard panel.preservesTaskHistory else { return }

        let key = ObjectIdentifier(panel)
        if let record = taskRecordLookup[key] {
            record.sync(from: panel)
        } else {
            registerTaskRecord(for: panel)
            return
        }

        sortTaskRecords()
    }

    private func removePanel(_ panel: FloatingPanel) {
        panels.removeAll { $0 === panel }

        let key = ObjectIdentifier(panel)
        if let record = taskRecordLookup.removeValue(forKey: key) {
            // Keep the record in the list if it has a persisted session on disk
            if let persistedId = panel.persistedSessionId {
                record.panel = nil
                record.persistedSessionId = persistedId
                record.isWindowVisible = false
                record.isRunning = false
            } else {
                taskRecords.removeAll { $0.id == record.id }
            }
        }
    }

    private func loadPersistedChatSessions() {
        let existingPersistedIds = Set(taskRecords.compactMap(\.persistedSessionId))
        let sessions = ChatSessionStore.shared.loadAll()
        for session in sessions where !existingPersistedIds.contains(session.id) {
            let record = TaskSessionRecord(persisted: session)
            taskRecords.append(record)
        }
        sortTaskRecords()
    }

    private func sortTaskRecords() {
        taskRecords = taskRecords.sorted { lhs, rhs in
            if lhs.lastActivityAt == rhs.lastActivityAt {
                return lhs.startedAt > rhs.startedAt
            }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
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

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    func createNewPanel() {
        panels.removeAll { !$0.isVisible && !$0.preservesTaskHistory }

        let panel = makePanel()
        panels.append(panel)
        panel.show()
    }

    func createNewPanel(at point: NSPoint) {
        // Close any existing search-mode panels (no message sent yet)
        for panel in panels where panel.isVisible && !panel.searchViewModel.isChatMode {
            panel.dismiss(restorePreviousFocus: false)
        }
        panels.removeAll { !$0.isVisible && !$0.preservesTaskHistory }

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
        guard let window = notification.object as? NSWindow else { return }

        if window == onboardingWindow {
            onboardingWindow = nil
        } else if window == settingsWindow {
            settingsWindow = nil
        }

        refreshApplicationPresentation()
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
