import AppKit
import SwiftUI

class FloatingPanel: NSPanel {
    private static let maxPanelDimension: CGFloat = 392
    private struct FocusRestorationState {
        weak var app: NSRunningApplication?
        let bundleIdentifier: String?
        let processIdentifier: pid_t
        let focusedWindow: AXUIElement?
        let focusedElement: AXUIElement?
    }
    let searchViewModel = SearchViewModel()
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalClickMonitor: Any?
    private var commandKeyMouseMonitor: Any?
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var dragStartMonitor: Any?
    private var pendingDragEvent: NSEvent?
    private var hostingView: NSHostingView<PanelContentView>!
    private var isTerminalMode = false
    private var isCommandKeyVisible = false
    private var isCursorFollowing = false
    private var isShiftHeld = false
    private var lastReportedContentSize: CGSize = .zero
    private var focusRestorationState: FocusRestorationState?
    private var shouldRestoreFocusOnClose = true
    private let voiceController = VoiceDictationController()
    var isCommandKeyHeld = false

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false

        hostingView = NSHostingView(rootView: PanelContentView(viewModel: searchViewModel))
        contentView = hostingView

        // Wire up the submit callback
        searchViewModel.onSubmit = { [weak self] context, screenshotURL in
            self?.transitionToTerminal(
                message: context,
                screenshotURL: screenshotURL
            )
        }
        searchViewModel.onClose = { [weak self] in
            self?.close()
        }
        searchViewModel.onContentSizeChange = { [weak self] size in
            self?.resizeToContentSize(size, preserveTopEdge: true)
        }
        voiceController.onStateChange = { [weak self] state in
            self?.handleVoiceStateChange(state)
        }
        voiceController.onLevelChange = { [weak self] level in
            self?.searchViewModel.voiceLevel = level
        }
        voiceController.onTranscript = { [weak self] transcript in
            guard let self else { return }
            self.searchViewModel.query = transcript
            self.searchViewModel.submitMessage()
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// In chat mode, make the entire window draggable except the text input and
    /// scroll area. Always dispatch mouseDown normally so buttons (like the close
    /// button) receive their events. If the mouse starts moving before the button
    /// is released, kick off a native window drag instead.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, isTerminalMode {
            cancelPendingDrag()
            let hit = contentView?.hitTest(event.locationInWindow)
            // Skip drag monitoring for scroll / text-input areas so they keep working.
            if !isScrollOrTextInput(hit) {
                pendingDragEvent = event
                dragStartMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDragged, .leftMouseUp]
                ) { [weak self] e in
                    guard let self else { return e }
                    if e.type == .leftMouseDragged, let original = self.pendingDragEvent {
                        self.cancelPendingDrag()
                        self.performDrag(with: original)
                        return nil  // consume — performDrag takes over tracking
                    }
                    if e.type == .leftMouseUp { self.cancelPendingDrag() }
                    return e
                }
            }
        }
        super.sendEvent(event)
    }

    private func cancelPendingDrag() {
        if let m = dragStartMonitor { NSEvent.removeMonitor(m); dragStartMonitor = nil }
        pendingDragEvent = nil
    }

    private func isScrollOrTextInput(_ view: NSView?) -> Bool {
        var v = view
        while let current = v {
            if current is NSScrollView || current is NSTextView { return true }
            v = current.superview
        }
        return false
    }

    func show(at point: NSPoint) {
        searchViewModel.query = ""
        searchViewModel.updateHoveredApp()
        installFlagsMonitors()
        isCursorFollowing = false

        let fittingSize = hostingView.fittingSize
        setContentSize(fittingSize)

        // Position at click point with slight offset, clamped to screen
        let x = point.x + 4
        let y = point.y - fittingSize.height - 4

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let sf = screen.visibleFrame
            let clampedX = max(sf.minX, min(x, sf.maxX - fittingSize.width))
            let clampedY = max(sf.minY, y)
            setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        } else {
            setFrameOrigin(NSPoint(x: x, y: y))
        }

        prepareForTextInputFocus()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Dismiss on click outside (no mouse-move monitors — panel stays anchored)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self, !self.isTerminalMode else { return }
            self.dismiss(restorePreviousFocus: false)
        }
    }

    func show() {
        searchViewModel.query = ""
        installFlagsMonitors()
        isCursorFollowing = true

        positionAtCursor()
        prepareForTextInputFocus()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Follow cursor
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.positionAtCursor()
            self?.searchViewModel.updateHoveredApp()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.positionAtCursor()
            self?.searchViewModel.updateHoveredApp()
            return event
        }

        // Dismiss on any click outside
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self, !self.isTerminalMode else { return }
            self.dismiss(restorePreviousFocus: false)
        }
    }

    func transitionToTerminal(
        message: String,
        screenshotURL: URL? = nil
    ) {
        isTerminalMode = true
        isCursorFollowing = false
        removeAllMonitors()

        // Convert to a normal titled window so it behaves like any other window:
        // standard z-ordering (click to front, other windows can go in front),
        // native traffic-light controls, and user-resizable.
        let previousTop = frame.maxY
        let previousOriginX = frame.minX
        styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        level = .normal
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        let chatSize = CGSize(width: 460, height: 200)
        setContentSize(chatSize)
        // Preserve position of the top-left corner, clamped to screen
        var nextOrigin = NSPoint(x: previousOriginX, y: previousTop - frame.height)
        if let scr = screen ?? NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
            let sf = scr.visibleFrame
            nextOrigin.x = max(sf.minX, min(nextOrigin.x, sf.maxX - frame.width))
            nextOrigin.y = max(sf.minY, min(nextOrigin.y, sf.maxY - frame.height))
        }
        setFrameOrigin(nextOrigin)

        // Switch to chat mode — the PanelContentView handles the rest
        searchViewModel.chatHistory.append((role: "user", text: searchViewModel.query))
        searchViewModel.query = ""

        let manager = ClaudeProcessManager()
        manager.onComplete = { [weak self] response in
            // Clear streaming text before appending to history to avoid duplicate display
            manager.outputText = ""
            self?.searchViewModel.chatHistory.append((role: "assistant", text: response))
            // Capture session ID for follow-up messages
            if let sid = manager.sessionId {
                self?.searchViewModel.currentSessionId = sid
            }
        }
        searchViewModel.claudeManager = manager
        searchViewModel.isChatMode = true

        manager.start(
            message: message,
            screenshotURL: screenshotURL
        )
    }

    private func positionAtCursor() {
        guard !isTerminalMode, !searchViewModel.isVoiceModeActive else { return }
        let fittingSize = hostingView.fittingSize
        setContentSize(fittingSize)

        let mouse = NSEvent.mouseLocation
        let x = mouse.x + 4
        let y = mouse.y - fittingSize.height - 4

        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            let clampedX = max(sf.minX, min(x, sf.maxX - fittingSize.width))
            let clampedY = max(sf.minY, y)
            setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        } else {
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func resizeToContentSize(_ size: CGSize, preserveTopEdge: Bool) {
        if isTerminalMode {
            // In terminal mode, grow the window to fit content (never shrink).
            // The window is already user-resizable; we only auto-expand.
            let maxHeight = (screen ?? NSScreen.main).map { $0.visibleFrame.height * 0.85 } ?? 700
            let targetHeight = min(ceil(size.height), maxHeight)
            guard targetHeight > frame.height + 0.5 else { return }
            let newOriginY = frame.maxY - targetHeight
            setFrame(NSRect(x: frame.minX, y: newOriginY, width: frame.width, height: targetHeight),
                     display: true, animate: false)
            return
        }
        let normalizedSize = CGSize(
            width: min(ceil(size.width), Self.maxPanelDimension),
            height: min(ceil(size.height), Self.maxPanelDimension)
        )
        guard normalizedSize.width > 0, normalizedSize.height > 0 else { return }
        guard abs(normalizedSize.width - lastReportedContentSize.width) > 0.5 ||
              abs(normalizedSize.height - lastReportedContentSize.height) > 0.5 else { return }
        lastReportedContentSize = normalizedSize

        guard isVisible else { return }

        let previousTop = frame.maxY
        let previousOriginX = frame.minX

        setContentSize(normalizedSize)

        guard preserveTopEdge else { return }

        var nextOrigin = NSPoint(x: previousOriginX, y: previousTop - frame.height)
        if let screen = screen ?? NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            nextOrigin.x = max(visibleFrame.minX, min(nextOrigin.x, visibleFrame.maxX - frame.width))
            nextOrigin.y = max(visibleFrame.minY, min(nextOrigin.y, visibleFrame.maxY - frame.height))
        }

        setFrameOrigin(nextOrigin)
    }

    // MARK: - Command key mode

    /// Called when ⌘ is pressed. Shows a minimal icon indicator immediately,
    /// then expands to the full panel on the first cursor move.
    func startCommandKeyMode() {
        installFlagsMonitors()
        searchViewModel.isCommandKeyMode = true
        searchViewModel.isMinimalMode = true
        searchViewModel.query = ""
        isCommandKeyVisible = false
        isCursorFollowing = true

        // Show the indicator right away at the current cursor position
        searchViewModel.updateHoveredApp()
        positionAtCursor()
        orderFront(nil)

        commandKeyMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            if !self.isCommandKeyVisible {
                self.isCommandKeyVisible = true
                self.searchViewModel.isMinimalMode = false
            }
            self.positionAtCursor()
            self.searchViewModel.updateHoveredApp()
        }
    }

    /// Called when ⌘ is released. Anchors the panel and shows the input row.
    /// If the panel was never shown (cursor didn't move), discard silently.
    func endCommandKeyMode() {
        if let m = commandKeyMouseMonitor { NSEvent.removeMonitor(m); commandKeyMouseMonitor = nil }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        isCursorFollowing = false

        if searchViewModel.isVoiceModeActive {
            searchViewModel.isCommandKeyMode = false
            searchViewModel.isMinimalMode = false
            return
        }

        guard isCommandKeyVisible else {
            dismiss(restorePreviousFocus: false)
            return
        }

        // Show input row if it was hidden
        if searchViewModel.isCommandKeyMode {
            searchViewModel.isCommandKeyMode = false
            prepareForTextInputFocus()
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Dismiss when cursor moves (unless ⌘ is held again or a message was sent)
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self, !self.isCommandKeyHeld, !self.searchViewModel.isChatMode else { return }
            self.dismiss()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self, !self.isCommandKeyHeld, !self.searchViewModel.isChatMode else { return event }
            self.dismiss()
            return event
        }
    }

    /// Re-enter cursor-following on an already-visible panel.
    /// Hides the input row only if no text has been typed yet.
    func restartCommandKeyMode() {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        if let m = commandKeyMouseMonitor { NSEvent.removeMonitor(m); commandKeyMouseMonitor = nil }

        installFlagsMonitors()
        isCommandKeyVisible = true
        isCursorFollowing = true
        if searchViewModel.query.isEmpty {
            searchViewModel.isCommandKeyMode = true
        }

        // Global monitor fires when another app is frontmost; local monitor fires when we are.
        commandKeyMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            self.positionAtCursor()
            self.searchViewModel.updateHoveredApp()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return event }
            self.positionAtCursor()
            self.searchViewModel.updateHoveredApp()
            return event
        }
    }

    private func removeAllMonitors() {
        for monitor in [
            globalMouseMonitor,
            localMouseMonitor,
            globalClickMonitor,
            commandKeyMouseMonitor,
            globalFlagsMonitor,
            localFlagsMonitor
        ].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        globalClickMonitor = nil
        commandKeyMouseMonitor = nil
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        cancelPendingDrag()
    }

    override func close() {
        let shouldRestoreFocus = shouldRestoreFocusOnClose
        let restorationState = focusRestorationState
        shouldRestoreFocusOnClose = true
        focusRestorationState = nil

        removeAllMonitors()
        voiceController.cancel()
        super.close()
        // Restore panel appearance for potential reuse
        if isTerminalMode {
            styleMask = [.borderless, .nonactivatingPanel]
            level = .screenSaver
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
        }
        searchViewModel.query = ""
        searchViewModel.isChatMode = false
        searchViewModel.isCommandKeyMode = false
        searchViewModel.isMinimalMode = false
        searchViewModel.voiceState = .idle
        searchViewModel.voiceLevel = 0
        searchViewModel.chatHistory = []
        searchViewModel.claudeManager = nil
        searchViewModel.currentSessionId = nil
        lastReportedContentSize = .zero
        isTerminalMode = false
        isCommandKeyVisible = false
        isCursorFollowing = false
        isCommandKeyHeld = false
        isShiftHeld = false

        if shouldRestoreFocus {
            restoreFocus(using: restorationState)
        }
    }

    // Handle Escape: stop streaming if active, otherwise close
    override func cancelOperation(_ sender: Any?) {
        if let manager = searchViewModel.claudeManager,
           manager.status == .waiting || manager.status == .streaming {
            manager.stop()
        } else {
            close()
        }
    }

    func dismiss(restorePreviousFocus: Bool = true) {
        shouldRestoreFocusOnClose = restorePreviousFocus
        close()
    }

    private func installFlagsMonitors() {
        if globalFlagsMonitor == nil {
            globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event)
            }
        }
        if localFlagsMonitor == nil {
            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event)
                return event
            }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let shiftDown = event.modifierFlags.contains(.shift)

        if shiftDown && !isShiftHeld {
            isShiftHeld = true
            startVoiceModeIfNeeded()
        } else if !shiftDown && isShiftHeld {
            isShiftHeld = false
            stopVoiceModeIfNeeded()
        }
    }

    private func startVoiceModeIfNeeded() {
        guard isVisible,
              !isTerminalMode,
              !searchViewModel.isChatMode,
              !searchViewModel.isMinimalMode,
              isCursorFollowing,
              !searchViewModel.isVoiceModeActive else { return }

        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
        if let monitor = commandKeyMouseMonitor {
            NSEvent.removeMonitor(monitor)
            commandKeyMouseMonitor = nil
        }

        isCursorFollowing = false
        searchViewModel.isCommandKeyMode = false
        searchViewModel.isMinimalMode = false
        voiceController.start()
    }

    private func stopVoiceModeIfNeeded() {
        if searchViewModel.voiceState == .listening {
            voiceController.stop()
        }
    }

    private func handleVoiceStateChange(_ state: VoiceDictationController.State) {
        switch state {
        case .idle:
            searchViewModel.voiceState = .idle
            searchViewModel.voiceLevel = 0
        case .listening:
            searchViewModel.voiceState = .listening
        case .transcribing:
            searchViewModel.voiceState = .transcribing
            searchViewModel.voiceLevel = 0
        case .failed(let message):
            searchViewModel.voiceState = .failed(message)
            searchViewModel.voiceLevel = 0

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.searchViewModel.voiceState == .failed(message) else { return }
                self.searchViewModel.voiceState = .idle
            }
        }
    }

    private func prepareForTextInputFocus() {
        guard focusRestorationState == nil,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let focusedWindow = axElementValue(appElement, key: kAXFocusedWindowAttribute)
        let focusedElement = axElementValue(appElement, key: kAXFocusedUIElementAttribute)

        focusRestorationState = FocusRestorationState(
            app: app,
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            focusedWindow: focusedWindow,
            focusedElement: focusedElement
        )
    }

    private func restoreFocus(using state: FocusRestorationState?) {
        guard let state, let app = runningApplication(for: state) else { return }

        app.activate(options: [.activateAllWindows])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let window = state.focusedWindow {
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            }

            if let element = state.focusedElement {
                _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
        }
    }

    private func runningApplication(for state: FocusRestorationState) -> NSRunningApplication? {
        if let app = state.app, !app.isTerminated {
            return app
        }

        if let bundleIdentifier = state.bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .first(where: { !$0.isTerminated })
        }

        return NSRunningApplication(processIdentifier: state.processIdentifier)
    }

    private func axValue(_ element: AXUIElement, key: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success else { return nil }
        return value
    }

    private func axElementValue(_ element: AXUIElement, key: String) -> AXUIElement? {
        guard let value = axValue(element, key: key) else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
}
