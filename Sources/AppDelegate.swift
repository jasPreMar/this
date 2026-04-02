import AppKit
import SwiftUI
import ApplicationServices
import Carbon
import Sparkle
import ThisCore
import WebKit

// Global reference for CGEventTap callback (C function pointers can't capture context)
private weak var sharedAppDelegate: AppDelegate?

private let commandMenuHotKeySignature: OSType = 0x48505452 // 'HPTR'

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

    guard let delegate = sharedAppDelegate else {
        return Unmanaged.passRetained(event)
    }

    if type == .rightMouseDown {
        let cgLocation = event.location
        let now = ProcessInfo.processInfo.systemUptime

        // Double right-click detection (within 0.5s)
        if (now - delegate.lastRightClickTime) < AppDelegate.rightClickDoubleClickInterval {
            delegate.lastRightClickTime = 0
            delegate.rightClickLongPressTimer?.invalidate()
            delegate.rightClickLongPressTimer = nil
            let point = cgLocation
            DispatchQueue.main.async {
                delegate.showRightClickPanel(at: point)
            }
            return Unmanaged.passRetained(event)
        }

        delegate.lastRightClickTime = now
        delegate.lastRightClickLocation = cgLocation

        // Start long-press timer
        delegate.rightClickLongPressTimer?.invalidate()
        let timer = Timer(timeInterval: AppDelegate.rightClickLongPressInterval, repeats: false) { _ in
            DispatchQueue.main.async {
                delegate.showRightClickPanel(at: delegate.lastRightClickLocation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        delegate.rightClickLongPressTimer = timer

        return Unmanaged.passRetained(event)
    }

    if type == .rightMouseUp {
        // Cancel long-press if released before threshold
        delegate.rightClickLongPressTimer?.invalidate()
        delegate.rightClickLongPressTimer = nil
        return Unmanaged.passRetained(event)
    }

    return Unmanaged.passRetained(event)
}

private func commandMenuHotKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout {
        if let tap = sharedAppDelegate?.hotKeyEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown,
          !NSApp.isActive else {
        return Unmanaged.passRetained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard keyCode == 49 else {
        return Unmanaged.passRetained(event)
    }

    let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
    guard InvokeHotKey.stored().isPressed(in: modifierFlags) else {
        return Unmanaged.passRetained(event)
    }

    DispatchQueue.main.async {
        sharedAppDelegate?.toggleCommandMenu(from: .invokeHotKey)
    }

    return Unmanaged.passRetained(event)
}

private func commandMenuCarbonHotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async {
        sharedAppDelegate?.toggleCommandMenu(from: .invokeHotKey)
    }
    return noErr
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    fileprivate enum CommandMenuPresentationSource {
        case statusItem
        case invokeHotKey
    }

    var panels: [FloatingPanel] = []
    @Published private(set) var taskRecords: [TaskSessionRecord] = []
    private var localHotKeyMonitor: Any?
    fileprivate var eventTap: CFMachPort?
    fileprivate var hotKeyEventTap: CFMachPort?
    private var commandMenuHotKeyRef: EventHotKeyRef?
    private var commandMenuHotKeyHandlerRef: EventHandlerRef?
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var statusItem: NSStatusItem?
    private var legacyStatusMenu: NSMenu?
    private var commandMenuPanel: CommandMenuPanel?
    private var commandMenuPresentationSource: CommandMenuPresentationSource?
    private var commandMenuPresentationID = UUID()
    private var commandMenuOpenedAt: TimeInterval = 0
    private var commandMenuCloseWorkItem: DispatchWorkItem?
    private var commandMenuGlobalMouseMonitor: Any?
    private var commandMenuLocalMouseMonitor: Any?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var panelsEligibleForClosedCommandMenuReveal: Set<ObjectIdentifier> = []
    private var commandKeyHeld = false
    private var lastInvokeKeyReleaseTime: TimeInterval = 0
    private static let doubleTapInterval: TimeInterval = 0.3
    fileprivate var lastRightClickTime: TimeInterval = 0
    fileprivate var lastRightClickLocation: CGPoint = .zero
    fileprivate var rightClickLongPressTimer: Timer?
    fileprivate static let rightClickDoubleClickInterval: TimeInterval = 0.5
    fileprivate static let rightClickLongPressInterval: TimeInterval = 0.5
    private weak var commandKeyPanel: FloatingPanel?
    private let commandMenuVoiceController = VoiceDictationController()
    private var updaterController: SPUStandardUpdaterController?
    private let onboardingSeenKey = "hasShownOnboarding"
    private let onboardingSeenInstallKey = "hasShownOnboardingInstallID"
    private var checkForUpdatesItem: NSMenuItem?
    private var updateDot: NSView?
    private var updateCheckTimer: Timer?
    private var feedbackPopover: NSPopover?
    private let soundPlayer = PTTSoundPlayer()
    private var taskRecordLookup: [ObjectIdentifier: TaskSessionRecord] = [:]
    @Published var commandMenuVoiceState: SearchViewModel.VoiceState = .idle
    @Published var commandMenuVoiceLevel: CGFloat = 0
    @Published var commandMenuChatRecord: TaskSessionRecord?
    @Published var commandMenuDismissing = false
    @Published var commandMenuQuery = ""
    @Published var commandMenuPinned = false {
        didSet { commandMenuPanel?.isPinned = commandMenuPinned }
    }
    private var rememberedCommandMenuChatRecordID: TaskSessionRecord.ID?
    private lazy var ghostCursorStore = GhostCursorStore(playClickSound: { [weak self] in
        self?.soundPlayer.playGhostCursorClick()
    })
    private var ghostCursorOverlayCoordinator: GhostCursorOverlayCoordinator?
    private let highlightOverlayStore = HighlightOverlayStore()
    private var highlightOverlayCoordinator: HighlightOverlayCoordinator?
    private var workspaceNotificationObservers: [NSObjectProtocol] = []
    private var hoverLoggingSession: HoverLoggingSession?
    private var defaultsObserver: NSObjectProtocol?
    private let quickActionCoordinator = QuickActionCoordinator()
    private var commandMenuInvocationSnapshot: ExternalFocusSnapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedAppDelegate = self
        AppSettings.registerDefaults()
        configureCommandMenuVoiceController()
        ghostCursorOverlayCoordinator = GhostCursorOverlayCoordinator(store: ghostCursorStore)
        highlightOverlayCoordinator = HighlightOverlayCoordinator(store: highlightOverlayStore)
        setupGhostCursorWorkspaceObservers()
        setupMainMenu()
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        setupStatusItem()
        checkForUpdateInBackground()
        setupRightClickTapIfNeeded()
        refreshCommandMenuHotKeyRegistration()
        loadPersistedChatSessions()
        showOnboardingIfNeeded()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshCommandMenuHotKeyRegistration()
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
            // Don't start voice on the command menu when user is interacting
            // with a floating panel alongside it.
            if commandKeyPanel == nil {
                syncCommandMenuVoice(with: modifierFlags, invokeKeyDown: invokeKeyDown)
            }
            // Allow floating panel creation/interaction to proceed below
            // so the cursor panel works alongside the command menu.
            if !invokeKeyDown && commandKeyHeld {
                commandKeyHeld = false
                lastInvokeKeyReleaseTime = ProcessInfo.processInfo.systemUptime
                if let panel = commandKeyPanel {
                    stopHoverLogging(keepRealtimeSessionAlive: panel.searchViewModel.voiceState == .listening || panel.searchViewModel.voiceState == .transcribing)
                    panel.isCommandKeyHeld = false
                    panel.updateModifierFlags(modifierFlags)
                    panel.endInvokeHoldMode()
                }
                commandKeyPanel = nil
                return
            }
            if !invokeKeyDown {
                return
            }
            // invokeKeyDown == true: fall through to create/manage floating panel
        }

        // Check if an existing panel is in pinned-follow mode
        if let pinnedPanel = panels.first(where: { $0.isVisible && $0.isPinnedFollowMode }) {
            if invokeKeyDown && !commandKeyHeld {
                commandKeyHeld = true
                pinnedPanel.handleInvokeKeyInPinnedMode()
            } else if !invokeKeyDown && commandKeyHeld {
                commandKeyHeld = false
                lastInvokeKeyReleaseTime = ProcessInfo.processInfo.systemUptime
            }
            return
        }

        if invokeKeyDown && !commandKeyHeld {
            commandKeyHeld = true

            // If a right-click-invoked (fixed) panel is visible, convert it to cursor-follow mode
            if let fixedPanel = panels.first(where: { $0.isVisible && $0.isRightClickInvoked && !$0.searchViewModel.isChatMode }) {
                fixedPanel.isRightClickInvoked = false
                commandKeyPanel = fixedPanel
                fixedPanel.isCommandKeyHeld = true
                fixedPanel.restartCommandKeyMode(with: modifierFlags)
                startHoverLogging(using: fixedPanel.searchViewModel)
                return
            }

            let now = ProcessInfo.processInfo.systemUptime
            let isDoubleTap = (now - lastInvokeKeyReleaseTime) < Self.doubleTapInterval

            if let selectedPanel = selectedVisiblePanel(),
               selectedPanel.searchViewModel.isChatMode {
                commandKeyPanel = selectedPanel
                selectedPanel.isCommandKeyHeld = true
                selectedPanel.startAnchoredVoiceMode(with: modifierFlags)
                startHoverLogging(using: selectedPanel.searchViewModel)
            } else if isDoubleTap {
                // Double-tap: enter pinned follow mode
                if let existing = panels.first(where: {
                    $0.isVisible && !$0.searchViewModel.isChatMode
                }) {
                    // Reuse existing panel — transition to pinned mode
                    commandKeyPanel = nil
                    existing.isCommandKeyHeld = false
                    existing.startPinnedFollowMode(with: modifierFlags)
                    startHoverLogging(using: existing.searchViewModel)
                } else {
                    panels.removeAll { !$0.isVisible && !$0.preservesTaskHistory }
                    let panel = makePanel()
                    panels.append(panel)
                    panel.startPinnedFollowMode(with: modifierFlags)
                    startHoverLogging(using: panel.searchViewModel)
                }
                // Release commandKeyHeld since pinned mode doesn't need it held
                commandKeyHeld = false
            } else if let existing = panels.first(where: {
                $0.isVisible && !$0.searchViewModel.isChatMode
            }) {
                commandKeyPanel = existing
                existing.isCommandKeyHeld = true
                existing.restartCommandKeyMode(with: modifierFlags)
                startHoverLogging(using: existing.searchViewModel)
            } else {
                panels.removeAll { !$0.isVisible && !$0.preservesTaskHistory }
                let panel = makePanel()
                commandKeyPanel = panel
                panels.append(panel)
                panel.startCommandKeyMode(with: modifierFlags)
                startHoverLogging(using: panel.searchViewModel)
            }
        } else if invokeKeyDown && commandKeyHeld {
            commandKeyPanel?.updateModifierFlags(modifierFlags)
        } else if !invokeKeyDown && commandKeyHeld {
            commandKeyHeld = false
            lastInvokeKeyReleaseTime = ProcessInfo.processInfo.systemUptime
            if let panel = commandKeyPanel {
                stopHoverLogging(keepRealtimeSessionAlive: panel.searchViewModel.voiceState == .listening || panel.searchViewModel.voiceState == .transcribing)
                panel.isCommandKeyHeld = false
                panel.updateModifierFlags(modifierFlags)
                panel.endInvokeHoldMode()
            } else {
                stopHoverLogging()
            }
            commandKeyPanel = nil
        }
    }

    private func startHoverLogging(using searchViewModel: SearchViewModel) {
        RealtimeInputLog.shared.startSession()
        hoverLoggingSession?.stop()
        let session = HoverLoggingSession(
            searchViewModel: searchViewModel,
            onPauseLogged: { snapshot in
                RealtimeInputLog.shared.recordHoverPause(snapshot)
            }
        )
        hoverLoggingSession = session
        session.start()
    }

    private func stopHoverLogging(keepRealtimeSessionAlive: Bool = false) {
        hoverLoggingSession?.stop()
        hoverLoggingSession = nil
        if !keepRealtimeSessionAlive {
            RealtimeInputLog.shared.stopSession()
        }
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> NSEvent? {
        if shouldSuppressQuitShortcut(for: event) {
            return nil
        }

        guard usesEventTapForCommandMenuHotKey else {
            return event
        }

        guard event.keyCode == 49,
              InvokeHotKey.stored().isPressed(in: event.modifierFlags) else {
            return event
        }

        toggleCommandMenu(from: .invokeHotKey)
        return nil
    }

    private func shouldSuppressQuitShortcut(for event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.keyCode == 12
        else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.command] else {
            return false
        }

        return panels.contains(where: { $0.isTypingInputActive })
    }

    // MARK: - Main Menu (key equivalents for text editing)

    /// Registers the standard macOS menu structure so window shortcuts continue
    /// to flow through the responder chain when This opens a normal app window.
    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "This"

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
            let iconImage: NSImage? = {
                if let img = Bundle.main.image(forResource: "StatusBarIcon") { return img }
                let bundleName = "This_This"
                if let resourceURL = Bundle.main.resourceURL {
                    let bundledURL = resourceURL
                        .appendingPathComponent("\(bundleName).bundle")
                        .appendingPathComponent("StatusBarIcon.png")
                    if let img = NSImage(contentsOf: bundledURL) { return img }
                }
                if let execURL = Bundle.main.executableURL?.deletingLastPathComponent() {
                    let bundledURL = execURL
                        .appendingPathComponent("\(bundleName).bundle")
                        .appendingPathComponent("StatusBarIcon.png")
                    if let img = NSImage(contentsOf: bundledURL) { return img }
                }
                return nil
            }()
            if let iconImage {
                iconImage.isTemplate = true
                iconImage.size = NSSize(width: 18, height: 18)
                button.image = iconImage
            } else {
                button.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "This")
            }
            button.imagePosition = .imageOnly
            button.toolTip = "This"
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let bundle = Bundle.main
        let shortVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let versionItem = NSMenuItem(title: "This v\(shortVersion)", action: nil, keyEquivalent: "")
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

        let quitItem = NSMenuItem(title: "Quit This", action: #selector(handleStatusQuit), keyEquivalent: "q")
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
            ghostCursorStore.unregisterTask(panel.taskId)
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
        if let resumeDestination = OnboardingViewModel.resumeDestinationOnLaunch {
            switch resumeDestination {
            case .onboarding:
                showOnboarding(force: true)
            case .settingsPermissions:
                showSettings(initialSection: .permissions)
            }
            OnboardingViewModel.clearResumeOnLaunch()
            return
        }

        if !hasSeenOnboardingForCurrentInstall() {
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

        if !force && hasSeenOnboardingForCurrentInstall() {
            return
        }

        let viewModel = OnboardingViewModel(
            onFinish: { [weak self] in
                guard let self else { return }
                UserDefaults.standard.set(true, forKey: self.onboardingSeenKey)
                UserDefaults.standard.set(self.currentOnboardingInstallIdentifier(), forKey: self.onboardingSeenInstallKey)
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
        window.title = "This Setup"
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

    private func hasSeenOnboardingForCurrentInstall() -> Bool {
        // Do not infer completion for a new app bundle from legacy global defaults.
        // A fresh DMG install on a machine that already granted permissions still
        // needs to show onboarding the first time that installed bundle launches.
        UserDefaults.standard.string(forKey: onboardingSeenInstallKey) == currentOnboardingInstallIdentifier()
    }

    private func currentOnboardingInstallIdentifier() -> String {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        if bundleURL.pathExtension == "app" {
            return installFingerprint(for: bundleURL)
        }

        let executableURL = (Bundle.main.executableURL ?? bundleURL).resolvingSymlinksInPath()
        return installFingerprint(for: executableURL)
    }

    private func installFingerprint(for url: URL) -> String {
        guard let resourceValues = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) else {
            return url.path
        }

        let creationTimestamp = resourceValues.creationDate?.timeIntervalSinceReferenceDate ?? 0
        let modificationTimestamp = resourceValues.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(url.path)#\(creationTimestamp)#\(modificationTimestamp)"
    }

    func openSettingsFromCommandMenu() {
        closeCommandMenu()
        showSettings()
    }

    func openFeedbackFromCommandMenu(draft: String? = nil) {
        closeCommandMenu()
        openFeedbackPage(draft: draft)
    }

    func checkForUpdatesFromCommandMenu() {
        closeCommandMenu()
        checkForUpdates()
    }

    func quitFromCommandMenu() {
        closeCommandMenu()
        NSApp.terminate(nil)
    }

    private func showSettings(initialSection: SettingsSection = .general) {
        closeCommandMenu()
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
        window.title = "This Settings"
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = NSHostingView(
            rootView: SettingsView(
                initialSection: initialSection,
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

    fileprivate func toggleCommandMenu(from source: CommandMenuPresentationSource) {
        if commandMenuPanel?.isVisible == true {
            closeCommandMenu()
        } else {
            showCommandMenu(from: source)
        }
    }

    private func commandMenuLevel(for source: CommandMenuPresentationSource) -> NSWindow.Level {
        .floating
    }

    private func commandMenuCollectionBehavior(for source: CommandMenuPresentationSource) -> NSWindow.CollectionBehavior {
        [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    private func showCommandMenu(from source: CommandMenuPresentationSource, navigateToChat: TaskSessionRecord? = nil) {
        commandMenuCloseWorkItem?.cancel()
        commandMenuCloseWorkItem = nil
        commandMenuDismissing = false
        commandMenuInvocationSnapshot = ExternalFocusInspector.captureCurrent()
        setCommandMenuChatRecord(resolvedCommandMenuChatRecord(preferred: navigateToChat))
        commandMenuPresentationSource = source
        commandMenuPresentationID = UUID()

        let targetScreen = commandMenuTargetScreen(for: source)

        if commandMenuPanel == nil {
            let panel = CommandMenuPanel(
                contentRect: targetScreen?.frame ?? .zero,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = commandMenuLevel(for: source)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = commandMenuCollectionBehavior(for: source)
            panel.isReleasedWhenClosed = false
            panel.onEscape = { [weak self] in
                self?.handleCommandMenuEscape()
            }
            panel.onClickOutsideContent = { [weak self] in
                self?.closeCommandMenu()
            }
            commandMenuPanel = panel
        }

        if source == .invokeHotKey {
            dismissCommandKeyPanelForCommandMenu()
        }

        commandMenuPanel?.isPinned = commandMenuPinned
        commandMenuPanel?.level = commandMenuLevel(for: source)
        commandMenuPanel?.collectionBehavior = commandMenuCollectionBehavior(for: source)
        commandMenuPanel?.setRootView(
            CommandMenuView(
                appDelegate: self,
                presentationID: commandMenuPresentationID
            )
        )

        if let screen = targetScreen {
            commandMenuPanel?.fillScreen(screen)
        }

        commandMenuOpenedAt = ProcessInfo.processInfo.systemUptime
        installCommandMenuEventMonitors()
        commandMenuPanel?.makeKeyAndOrderFront(nil)
        statusItem?.button?.highlight(source == .statusItem)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateCommandMenuContentFrame(_ frame: CGRect) {
        guard let panel = commandMenuPanel else { return }
        // Convert from SwiftUI global coordinates to window coordinates
        let windowFrame = panel.frame
        let contentInWindow = CGRect(
            x: frame.minX - windowFrame.minX,
            y: frame.minY - windowFrame.minY,
            width: frame.width,
            height: frame.height
        )
        panel.updateContentFrame(contentInWindow)
    }

    private func commandMenuTargetScreen(for source: CommandMenuPresentationSource) -> NSScreen? {
        switch source {
        case .statusItem:
            guard let statusButton = statusItem?.button,
                  let buttonWindow = statusButton.window else { return NSScreen.main }
            let buttonFrame = buttonWindow.frame
            return NSScreen.screens.first(where: { $0.frame.intersects(buttonFrame) }) ?? NSScreen.main
        case .invokeHotKey:
            return NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
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

        // Global monitor for clicks in OTHER windows/apps (outside our full-screen panel)
        commandMenuGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            // Ignore clicks that arrive within a short grace period after opening —
            // the mouseDown that preceded the status-bar mouseUp (which opened us)
            // can be delivered to the global monitor immediately.
            let elapsed = ProcessInfo.processInfo.systemUptime - self.commandMenuOpenedAt
            guard elapsed > 0.3 else { return }
            let screenPoint = NSEvent.mouseLocation
            // Let clicks on the status item toggle normally
            if let statusButtonRect = self.statusButtonScreenRect(), statusButtonRect.contains(screenPoint) {
                return
            }
            // When unpinned, clicking outside dismisses
            if !self.commandMenuPinned {
                self.closeCommandMenu()
            }
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
            refreshCommandMenuHotKeyRegistration()
        } else {
            tearDownRightClickTap()
            tearDownHotKeyTap()
            unregisterCommandMenuHotKey()
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

    private func setupHotKeyTapIfNeeded() {
        guard hotKeyEventTap == nil, AXIsProcessTrusted() else { return }
        setupHotKeyTap()
    }

    private func tearDownHotKeyTap() {
        guard let tap = hotKeyEventTap else { return }
        CFMachPortInvalidate(tap)
        hotKeyEventTap = nil
    }

    private func setupRightClickTap() {
        let eventMask: CGEventMask = (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
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

    private func setupHotKeyTap() {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: commandMenuHotKeyCallback,
            userInfo: nil
        ) else {
            print("Failed to create hotkey event tap — ensure Accessibility/Input Monitoring permissions are granted.")
            return
        }

        hotKeyEventTap = tap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private var usesEventTapForCommandMenuHotKey: Bool {
        InvokeHotKey.stored() == .function
    }

    private func refreshCommandMenuHotKeyRegistration() {
        if usesEventTapForCommandMenuHotKey {
            unregisterCommandMenuHotKey()
            setupHotKeyTapIfNeeded()
        } else {
            tearDownHotKeyTap()
            registerCommandMenuHotKey()
        }
    }

    private func registerCommandMenuHotKey() {
        guard let modifiers = carbonModifiers(for: InvokeHotKey.stored()) else { return }

        installCommandMenuHotKeyHandlerIfNeeded()
        unregisterCommandMenuHotKey()

        let hotKeyID = EventHotKeyID(signature: commandMenuHotKeySignature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &commandMenuHotKeyRef
        )

        if status != noErr {
            print("Failed to register command menu hotkey: \(status)")
        }
    }

    private func unregisterCommandMenuHotKey() {
        guard let hotKeyRef = commandMenuHotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        commandMenuHotKeyRef = nil
    }

    private func installCommandMenuHotKeyHandlerIfNeeded() {
        guard commandMenuHotKeyHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            commandMenuCarbonHotKeyHandler,
            1,
            &eventType,
            nil,
            &commandMenuHotKeyHandlerRef
        )
    }

    private func carbonModifiers(for hotKey: InvokeHotKey) -> UInt32? {
        switch hotKey {
        case .command:
            return UInt32(cmdKey)
        case .option:
            return UInt32(optionKey)
        case .control:
            return UInt32(controlKey)
        case .function:
            return nil
        }
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel()
        panel.quickActionCoordinator = quickActionCoordinator
        panel.onCommandKeyDropped = { [weak self, weak panel] in
            guard let panel else { return }
            self?.commandKeyHeld = false
            let keepRealtimeSessionAlive = panel.searchViewModel.voiceState == .listening || panel.searchViewModel.voiceState == .transcribing
            self?.commandKeyPanel = nil
            self?.stopHoverLogging(keepRealtimeSessionAlive: keepRealtimeSessionAlive)
        }
        panel.onMessageSent = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.ghostCursorStore.registerTask(panel.taskId, anchorPoint: panel.ghostCursorAnchorPoint)
            self.ghostCursorStore.setTaskVisible(panel.taskId, visible: false)
        }
        panel.onStreamingBegan = { [weak self] in
            if UserDefaults.standard.bool(forKey: "chimeEnabled") {
                self?.soundPlayer.playPress()
            }
        }
        panel.onStreamingComplete = { [weak self, weak panel] in
            if UserDefaults.standard.bool(forKey: "chimeEnabled") {
                self?.soundPlayer.playRelease()
            }
            guard let self, let panel else { return }
            self.ghostCursorStore.setTaskVisible(panel.taskId, visible: false)
            self.handleCompletedTaskVisibilityIfNeeded(for: panel)
        }
        panel.onPersistentTaskStarted = { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            self.registerTaskRecord(for: panel)
            self.ghostCursorStore.registerTask(panel.taskId, anchorPoint: panel.ghostCursorAnchorPoint)
            self.ghostCursorStore.setTaskVisible(panel.taskId, visible: false)
        }
        panel.onTaskStateChanged = { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            self.syncTaskRecord(for: panel)
            self.ghostCursorStore.registerTask(panel.taskId, anchorPoint: panel.ghostCursorAnchorPoint)
            if !panel.isTaskRunning {
                self.ghostCursorStore.setTaskVisible(panel.taskId, visible: false)
            }
            self.handleCompletedTaskVisibilityIfNeeded(for: panel)
        }
        panel.onPanelDestroyed = { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            self.ghostCursorStore.unregisterTask(panel.taskId)
            self.removePanel(panel)
        }
        panel.onInterceptSubmission = { [weak self, weak panel] query in
            guard let self, let panel, self.commandMenuPanel?.isVisible == true else { return false }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }

            // Build context-enriched message using the inline [hovered ...] format
            let vm = panel.searchViewModel
            let hoverPrefix = Self.inlineHoverPrefix(parts: vm.hoveredParts)
            let contextMessage = hoverPrefix.isEmpty ? trimmed : "\(hoverPrefix) \(trimmed)"

            if let chatRecord = self.commandMenuChatRecord,
               let chatPanel = chatRecord.panel {
                // Route to the currently open chat tab with context
                chatPanel.searchViewModel.query = contextMessage
                chatPanel.searchViewModel.submitMessage()
            } else {
                // No chat open — launch a new task via command menu.
                // Use startHeadless directly to avoid double-wrapping context.
                let newPanel = self.makePanel()
                self.panels.append(newPanel)
                newPanel.searchViewModel.query = contextMessage
                newPanel.startHeadless(
                    message: contextMessage,
                    workingDirectoryURL: vm.hoveredWorkingDirectoryURL
                )
                if let record = self.taskRecordLookup[ObjectIdentifier(newPanel)] {
                    self.openTaskRecord(record)
                }
            }
            return true
        }
        panel.onTransitionToCommandMenu = { [weak self, weak panel] _ in
            guard let self, let panel else { return }
            panel.dismiss(restorePreviousFocus: false)
            self.markPanelEligibleForClosedCommandMenuReveal(panel)
        }
        panel.highlightOverlayStore = highlightOverlayStore
        panel.onGhostCursorIntent = { [weak self, weak panel] intent in
            guard let self, let panel else { return }
            self.ghostCursorStore.registerTask(panel.taskId, anchorPoint: panel.ghostCursorAnchorPoint)

            guard intent.revealsCursor else {
                self.ghostCursorStore.setTaskVisible(panel.taskId, visible: false)
                return
            }

            self.ghostCursorStore.setTaskVisible(panel.taskId, visible: true)
            let activity = GhostCursorResolver.resolve(
                taskId: panel.taskId,
                intent: intent,
                context: panel.ghostCursorResolutionContext
            )
            self.ghostCursorStore.emit(activity: activity)
            if case .appLaunch(let appName) = intent {
                self.ghostCursorStore.trackPendingLaunch(taskId: panel.taskId, appName: appName)
            }
        }
        return panel
    }

    @discardableResult
    func launchTaskFromCommandMenu(query: String) -> TaskSessionRecord? {
        let panel = makePanel()
        panel.quickActionSurface = .commandMenu
        panel.externalInvocationSnapshot = commandMenuInvocationSnapshot
        panels.append(panel)
        panel.startTaskFromMenuHeadless(query: query)
        let key = ObjectIdentifier(panel)
        guard let record = taskRecordLookup[key] else { return nil }
        openTaskRecord(record)
        return record
    }

    func openTaskRecord(_ record: TaskSessionRecord) {
        record.isUnread = false
        ensureTaskHasLivePanel(record)
        setCommandMenuChatRecord(record)
    }

    func stopTaskRecord(_ record: TaskSessionRecord) {
        record.panel?.searchViewModel.claudeManager?.stop()
    }

    func stopAllRunningTaskRecords() {
        for record in taskRecords where record.isRunning {
            stopTaskRecord(record)
        }
    }

    func deleteTaskRecord(_ record: TaskSessionRecord) {
        if rememberedCommandMenuChatRecordID == record.id {
            clearCommandMenuChatRecord()
        }

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
        if let commandMenuChatRecord {
            rememberedCommandMenuChatRecordID = commandMenuChatRecord.id
        }
        commandMenuVoiceController.cancel()
        commandMenuVoiceState = .idle
        commandMenuVoiceLevel = 0
        tearDownCommandMenuEventMonitors()
        statusItem?.button?.highlight(false)

        // Trigger exit animation, then order out after it completes.
        // Keep commandMenuChatRecord alive during the animation so the
        // content freezes in place (no height collapse / placeholder swap).
        commandMenuDismissing = true
        commandMenuCloseWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.commandMenuDismissing else { return }
            self.commandMenuChatRecord = nil
            self.commandMenuPanel?.orderOut(nil)
            self.commandMenuPanel = nil
            self.commandMenuPresentationSource = nil
            self.commandMenuDismissing = false
            self.commandMenuCloseWorkItem = nil
        }
        commandMenuCloseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    func handleCommandMenuBackNavigation() {
        clearCommandMenuChatRecord()
    }

    func handleCommandMenuEscape() {
        if let chatRecord = commandMenuChatRecord {
            if let manager = chatRecord.panel?.searchViewModel.claudeManager,
               manager.status.isActive {
                manager.stop()
            } else {
                clearCommandMenuChatRecord()
            }
        } else {
            closeCommandMenu()
        }
    }

    func ensureTaskHasLivePanel(_ record: TaskSessionRecord) {
        if record.panel != nil { return }

        guard let persistedId = record.persistedSessionId else { return }
        let sessions = ChatSessionStore.shared.loadAll()
        guard let session = sessions.first(where: { $0.id == persistedId }) else { return }

        let panel = makePanel()
        panels.append(panel)
        panel.persistedSessionId = persistedId

        let workingDirectoryURL = session.workingDirectoryPath.map { URL(fileURLWithPath: $0) }

        panel.searchViewModel.chatHistory = session.messages.map {
            ChatMessage(role: $0.role, text: $0.text, structuredUI: $0.structuredUI)
        }
        panel.searchViewModel.currentSessionId = session.sessionId
        panel.searchViewModel.currentSessionWorkingDirectoryURL = workingDirectoryURL
        panel.searchViewModel.hasStartedClaudeConversation = session.sessionId != nil

        panel.restoreHeadless(workingDirectoryURL: workingDirectoryURL)

        record.panel = panel
        let key = ObjectIdentifier(panel)
        taskRecordLookup[key] = record
    }

    private func registerTaskRecord(for panel: FloatingPanel) {
        let key = ObjectIdentifier(panel)
        if let existing = taskRecordLookup[key] {
            existing.sync(from: panel)
            objectWillChange.send()
            return
        }

        let record = TaskSessionRecord(panel: panel)
        record.persistedSessionId = panel.persistedSessionId
        taskRecordLookup[key] = record
        taskRecords.append(record)
    }

    private func syncTaskRecord(for panel: FloatingPanel) {
        guard panel.preservesTaskHistory else { return }

        let key = ObjectIdentifier(panel)
        if let record = taskRecordLookup[key] {
            record.sync(from: panel)
            objectWillChange.send()
        } else {
            registerTaskRecord(for: panel)
        }
    }

    private func removePanel(_ panel: FloatingPanel) {
        panels.removeAll { $0 === panel }

        let key = ObjectIdentifier(panel)
        panelsEligibleForClosedCommandMenuReveal.remove(key)
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
        // Sort once on load: oldest first (leftmost), newest last (rightmost).
        taskRecords.sort { $0.startedAt < $1.startedAt }
    }

    private func markPanelEligibleForClosedCommandMenuReveal(_ panel: FloatingPanel) {
        let key = ObjectIdentifier(panel)
        panelsEligibleForClosedCommandMenuReveal.insert(key)
    }

    private func handleCompletedTaskVisibilityIfNeeded(for panel: FloatingPanel) {
        let key = ObjectIdentifier(panel)
        guard panel.taskCompletedAt != nil,
              let record = taskRecordLookup[key] else { return }

        let wasEligibleForReveal = panelsEligibleForClosedCommandMenuReveal.remove(key) != nil
        let shouldRevealNow = shouldRevealCommandMenuOnCompletion(
            isEligibleForReveal: wasEligibleForReveal,
            completionAction: panel.lastCompletedCommandMenuAction,
            isCommandMenuVisible: commandMenuPanel?.isVisible == true,
            isCommandMenuDismissing: commandMenuDismissing
        )

        if shouldRevealNow {
            record.isUnread = false
            showCommandMenu(from: .invokeHotKey, navigateToChat: record)
        } else {
            record.isUnread = !isTaskCurrentlyVisibleToUser(record)
            objectWillChange.send()
        }
    }

    private func setCommandMenuChatRecord(_ record: TaskSessionRecord?) {
        commandMenuChatRecord = record
        rememberedCommandMenuChatRecordID = record?.id
    }

    private func clearCommandMenuChatRecord() {
        commandMenuChatRecord = nil
        rememberedCommandMenuChatRecordID = nil
    }

    private func resolvedCommandMenuChatRecord(preferred record: TaskSessionRecord?) -> TaskSessionRecord? {
        if let record {
            ensureTaskHasLivePanel(record)
            return record
        }

        guard let rememberedID = rememberedCommandMenuChatRecordID,
              let rememberedRecord = taskRecords.first(where: { $0.id == rememberedID }) else {
            return nil
        }

        ensureTaskHasLivePanel(rememberedRecord)
        return rememberedRecord
    }

    private func isTaskCurrentlyVisibleToUser(_ record: TaskSessionRecord) -> Bool {
        if record.panel?.isVisible == true {
            return true
        }

        return commandMenuPanel?.isVisible == true && commandMenuChatRecord?.id == record.id
    }

    private func selectedVisiblePanel() -> FloatingPanel? {
        if let keyPanel = NSApp.keyWindow as? FloatingPanel, keyPanel.isVisible {
            return keyPanel
        }

        if let mainPanel = NSApp.mainWindow as? FloatingPanel, mainPanel.isVisible {
            return mainPanel
        }

        return nil
    }

    private func setupGhostCursorWorkspaceObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter

        let launched = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleGhostCursorLaunchNotification(notification)
        }

        let activated = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleGhostCursorApplicationNotification(notification)
        }

        workspaceNotificationObservers = [launched, activated]
    }

    private func handleGhostCursorApplicationNotification(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        ghostCursorStore.handleActivatedApplication(
            application,
            windowFrame: frontmostWindowFrame(for: application.processIdentifier)
        )
    }

    private func handleGhostCursorLaunchNotification(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        if frontmostWindowFrame(for: application.processIdentifier) != nil {
            handleGhostCursorApplicationNotification(notification)
        }
    }

    private func frontmostWindowFrame(for pid: pid_t) -> CGRect? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid else { continue }
            let layer = window[kCGWindowLayer as String] as? Int ?? 999
            guard layer == 0 else { continue }

            var bounds = CGRect.zero
            if let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
               CGRectMakeWithDictionaryRepresentation(boundsDictionary as CFDictionary, &bounds),
               bounds.width > 10,
               bounds.height > 10 {
                return bounds
            }
        }

        return nil
    }

    private func configureCommandMenuVoiceController() {
        commandMenuVoiceController.onStateChange = { [weak self] state in
            self?.handleCommandMenuVoiceStateChange(state)
        }
        commandMenuVoiceController.onLevelChange = { [weak self] level in
            self?.commandMenuVoiceLevel = level
        }
        commandMenuVoiceController.onTranscript = { [weak self] transcript in
            guard let self, self.commandMenuPanel?.isVisible == true else { return }
            self.launchTaskFromCommandMenu(query: transcript)
        }
    }

    private func syncCommandMenuVoice(with modifierFlags: NSEvent.ModifierFlags, invokeKeyDown: Bool) {
        guard commandMenuPanel?.isVisible == true else {
            cancelCommandMenuVoiceIfNeeded()
            return
        }

        if invokeKeyDown {
            guard AppSettings.autoVoiceEnabled || modifierFlags.contains(.shift) else {
                cancelCommandMenuVoiceIfNeeded()
                return
            }

            startCommandMenuVoiceIfNeeded()
            return
        }

        stopCommandMenuVoiceIfNeeded()
    }

    func toggleCommandMenuVoice() {
        switch commandMenuVoiceState {
        case .idle, .failed:
            startCommandMenuVoiceIfNeeded()
        case .listening:
            stopCommandMenuVoiceIfNeeded()
        case .transcribing:
            break
        }
    }

    private func startCommandMenuVoiceIfNeeded() {
        guard commandMenuPanel?.isVisible == true else { return }

        switch commandMenuVoiceState {
        case .idle:
            commandMenuVoiceController.start()
        case .listening, .transcribing, .failed:
            break
        }
    }

    private func cancelCommandMenuVoiceIfNeeded() {
        switch commandMenuVoiceState {
        case .listening, .idle:
            commandMenuVoiceController.cancel()
        case .transcribing, .failed:
            break
        }
    }

    private func stopCommandMenuVoiceIfNeeded() {
        switch commandMenuVoiceState {
        case .listening:
            commandMenuVoiceController.stop()
        case .idle:
            commandMenuVoiceController.cancel()
        case .transcribing, .failed:
            break
        }
    }

    private func handleCommandMenuVoiceStateChange(_ state: VoiceDictationController.State) {
        switch state {
        case .idle:
            commandMenuVoiceState = .idle
            commandMenuVoiceLevel = 0
        case .listening:
            commandMenuVoiceState = .listening
        case .transcribing:
            commandMenuVoiceState = .transcribing
            commandMenuVoiceLevel = 0
        case .failed(let message):
            commandMenuVoiceState = .failed(message)
            commandMenuVoiceLevel = 0

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.commandMenuVoiceState == .failed(message) else { return }
                self.commandMenuVoiceState = .idle
            }
        }
    }

    func openFeedbackPage(draft: String? = nil) {
        guard let url = URL(string: "https://prickly-perfume-f62.notion.site/ebd/5ca57834b3ec456eba024dc6ac60a337") else {
            return
        }

        let trimmedDraft = draft?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedDraft, !trimmedDraft.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(trimmedDraft, forType: .string)
        }

        guard let button = statusItem?.button else {
            NSWorkspace.shared.open(url)
            return
        }

        // Toggle the feedback popover if already shown.
        if let existing = feedbackPopover, existing.isShown {
            existing.performClose(nil)
            feedbackPopover = nil
            if trimmedDraft == nil || trimmedDraft?.isEmpty == true {
                return
            }
        }

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 580))
        let focusDelegate = FeedbackWebViewDelegate(draftText: trimmedDraft)
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

    /// Show a fixed (non-following) panel invoked by double-right-click or long-press right-click.
    fileprivate func showRightClickPanel(at cgPoint: CGPoint) {
        // Dismiss any context menu by sending Escape
        if let escDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true) {
            escDown.post(tap: .cghidEventTap)
        }
        if let escUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: false) {
            escUp.post(tap: .cghidEventTap)
        }

        // Brief delay to let the context menu dismiss before querying accessibility
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
            // Convert CG coordinates (top-left origin) to NS coordinates (bottom-left origin)
            guard let screen = NSScreen.screens.first(where: {
                $0.frame.contains(NSPoint(x: cgPoint.x, y: $0.frame.height - cgPoint.y))
            }) ?? NSScreen.main else { return }

            let nsPoint = NSPoint(
                x: cgPoint.x,
                y: screen.frame.height - cgPoint.y
            )

            // Close any existing search-mode panels
            for panel in panels where panel.isVisible && !panel.searchViewModel.isChatMode {
                panel.dismiss(restorePreviousFocus: false)
            }
            panels.removeAll { !$0.isVisible && !$0.preservesTaskHistory }

            let panel = makePanel()
            panels.append(panel)
            panel.isRightClickInvoked = true
            panel.show(at: nsPoint)
        }
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

    /// Builds a `[hovered X in App]` prefix from hover parts, matching
    /// the format used by `HoverSnapshot.inlineLogText`.
    static func inlineHoverPrefix(parts: [String]) -> String {
        guard !parts.isEmpty else { return "" }
        let appName = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetPart = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let targetText: String
        if let separatorRange = targetPart.range(of: ": ") {
            targetText = String(targetPart[separatorRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if !targetPart.isEmpty {
            targetText = targetPart
        } else {
            targetText = "item"
        }

        if !appName.isEmpty && targetText != appName {
            return "[hovered \(targetText) in \(appName)]"
        }
        return "[hovered \(targetText)]"
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
    private let draftText: String?

    init(draftText: String? = nil) {
        self.draftText = draftText
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Notion forms render dynamically; delay slightly to let React mount the fields.
        let draftScriptArgument = draftText.flatMap(Self.jsonEncodedString) ?? "null"
        webView.evaluateJavaScript(
            """
            (function(draftText) {
                function focusAndPopulateField() {
                    var selectors = [
                        'textarea',
                        'input:not([type="hidden"]):not([type="email"])',
                        '[contenteditable="true"]',
                        'input[type="email"]'
                    ];
                    var nodes = [];
                    selectors.forEach(function(selector) {
                        nodes = nodes.concat(Array.from(document.querySelectorAll(selector)));
                    });

                    var field = nodes.find(function(node) {
                        if (!node) { return false; }
                        if (node.getAttribute('aria-hidden') === 'true') { return false; }
                        if (node.disabled) { return false; }
                        return true;
                    });

                    if (!field) { return false; }

                    field.focus();

                    if (draftText && draftText.length > 0) {
                        if (field.isContentEditable) {
                            field.textContent = draftText;
                        } else {
                            field.value = draftText;
                        }
                        field.dispatchEvent(new Event('input', { bubbles: true }));
                        field.dispatchEvent(new Event('change', { bubbles: true }));
                    }

                    return true;
                }

                var attempts = 0;
                var timer = setInterval(function() {
                    attempts += 1;
                    if (focusAndPopulateField() || attempts >= 14) {
                        clearInterval(timer);
                    }
                }, 300);
            })(\(draftScriptArgument));
            """,
            completionHandler: nil
        )
    }

    private static func jsonEncodedString(_ string: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let encoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return encoded.dropFirst().dropLast().description
    }
}
