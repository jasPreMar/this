import AppKit
import SwiftUI
import Combine
import ThisCore

class FloatingPanel: NSPanel {
    private static let maxPanelDimension: CGFloat = 392
    private enum InvokeHoldBehavior {
        case cursorFollow
        case anchoredInput
        case pinnedFollow
    }

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
    private var dragStartMonitor: Any?
    private var pendingDragEvent: NSEvent?
    private var hostingView: NSHostingView<PanelContentView>!
    private var glassEffectView: NSView?
    private var isTerminalMode = false
    private var isCommandKeyVisible = false
    private var isCursorFollowing = false
    private var isDestroyingTaskWindow = false
    private var currentModifierFlags: NSEvent.ModifierFlags = []
    private var lastReportedContentSize: CGSize = .zero
    private var focusRestorationState: FocusRestorationState?
    private var shouldRestoreFocusOnClose = true
    private let voiceController = VoiceDictationController()
    private var pendingRealtimeLogStopWorkItem: DispatchWorkItem?
    private var safeTriangleApex: NSPoint?
    private var invokeHoldBehavior: InvokeHoldBehavior?
    private var pinnedPauseWorkItem: DispatchWorkItem?
    private var pinnedInputVisible = false
    private var escapeKeyMonitor: Any?
    private var pinnedLocalMouseMonitor: Any?
    private var isTaskIconMode = false
    private var taskIconWindowID: CGWindowID?
    private var taskIconWindowOffset: CGPoint?
    private var taskIconAnchorOrigin: NSPoint? // top-left anchor for the 36x36 icon
    private var taskIconFollowTimer: Timer?
    private var taskIconHoverMonitor: Any?
    private var taskIconLocalHoverMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private(set) var taskStartedAt: Date?
    private(set) var taskCompletedAt: Date?
    private(set) var taskLastActivityAt: Date?
    private(set) var preservesTaskHistory = false
    private(set) var lastCompletedCommandMenuAction: CommandMenuCompletionAction = .reveal
    let taskId = UUID()
    var persistedSessionId: String?
    var isCommandKeyHeld = false
    var isRightClickInvoked = false
    var isPinnedFollowMode: Bool { invokeHoldBehavior == .pinnedFollow }
    var onCommandKeyDropped: (() -> Void)?
    var onMessageSent: (() -> Void)?
    var onStreamingBegan: (() -> Void)?
    var onStreamingComplete: (() -> Void)?
    var onPersistentTaskStarted: ((FloatingPanel) -> Void)?
    var onTaskStateChanged: ((FloatingPanel) -> Void)?
    var onPanelDestroyed: ((FloatingPanel) -> Void)?
    var onGhostCursorIntent: ((GhostCursorIntent) -> Void)?
    var onTransitionToCommandMenu: ((FloatingPanel) -> Void)?
    /// If set and returns true, the submission was handled externally (e.g. routed
    /// to the command menu chat). The floating panel skips its default behavior.
    var onInterceptSubmission: ((String) -> Bool)?
    weak var highlightOverlayStore: HighlightOverlayStore?
    var quickActionCoordinator: QuickActionCoordinator?
    var quickActionSurface: FastCommandSurface = .cursorPanel
    var externalInvocationSnapshot: ExternalFocusSnapshot?
    private var recentQuickActionInvocationSnapshot: ExternalFocusSnapshot?

    var taskDisplayTitle: String {
        let fallback = searchViewModel.query.isEmpty ? "New task" : searchViewModel.query
        return Self.normalizedContextText(searchViewModel.hoveredParts.last) ?? fallback
    }

    var taskDisplaySubtitle: String {
        guard let firstPart = searchViewModel.hoveredParts.first else { return "" }
        let subtitle = Self.normalizedContextText(firstPart) ?? ""
        return subtitle == taskDisplayTitle ? "" : subtitle
    }

    var taskDisplayIcon: NSImage? {
        searchViewModel.hoveredContextIcon
    }

    var isTaskRunning: Bool {
        searchViewModel.claudeManager?.status.isActive ?? false
    }

    var currentStreamStartedAt: Date? {
        searchViewModel.claudeManager?.currentStreamStartedAt
    }

    var ghostCursorAnchorPoint: CGPoint {
        if let hoveredScreenPoint = searchViewModel.hoveredScreenPoint {
            return hoveredScreenPoint
        }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    var ghostCursorResolutionContext: GhostCursorResolutionContext {
        GhostCursorResolutionContext(
            panelFrame: isVisible ? frame : nil,
            hoveredElementFrame: searchViewModel.hoveredElementFrame,
            hoveredWindowFrame: searchViewModel.hoveredWindowFrame,
            hoveredScreenPoint: searchViewModel.hoveredScreenPoint,
            hoveredParts: searchViewModel.hoveredParts,
            workingDirectoryURL: searchViewModel.currentSessionWorkingDirectoryURL ?? searchViewModel.hoveredWorkingDirectoryURL
        )
    }

    private var usesNativeGlassSurface: Bool {
        NativeGlass.isSupported
    }

    private var currentGlassCornerRadius: CGFloat {
        searchViewModel.isMinimalMode ? 10 : 14
    }

    private func normalizedFloatingBodySize(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(ceil(size.width), Self.maxPanelDimension),
            height: min(ceil(size.height), Self.maxPanelDimension)
        )
    }

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
        hostingView.autoresizingMask = [.width, .height]
        installFloatingSurface()

        // Wire up the submit callback
        searchViewModel.onSubmit = { [weak self] context, workingDirectoryURL in
            guard let self else { return }
            // Allow external interception (e.g. routing to command menu chat)
            if let intercept = self.onInterceptSubmission, intercept(self.searchViewModel.query) {
                self.dismiss(restorePreviousFocus: false)
                return
            }
            let rawPrompt = self.searchViewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
            if self.onTransitionToCommandMenu != nil {
                self.startTaskIconMode(
                    rawPrompt: rawPrompt,
                    claudeMessage: context,
                    workingDirectoryURL: workingDirectoryURL
                )
            } else {
                self.transitionToTerminalWithRouting(
                    rawPrompt: rawPrompt,
                    claudeMessage: context,
                    workingDirectoryURL: workingDirectoryURL
                )
            }
        }
        searchViewModel.onQuickActionSubmit = { [weak self] rawPrompt, workingDirectoryURL in
            guard let self else { return false }
            return self.routeChatTurnBeforeClaude(
                rawPrompt: rawPrompt,
                claudeMessage: rawPrompt,
                workingDirectoryURL: workingDirectoryURL
            )
        }
        searchViewModel.onMessageSent = { [weak self] in
            self?.markTaskActivity()
            self?.onMessageSent?()
        }
        searchViewModel.onStreamingComplete = { [weak self] in
            self?.lastCompletedCommandMenuAction = self?.searchViewModel.claudeManager?.completionAction ?? .reveal
            self?.markTaskActivity(completed: true)
            self?.onStreamingComplete?()
        }
        searchViewModel.onClaudeManagerChange = { [weak self] manager in
            self?.configureClaudeManager(manager)
        }
        searchViewModel.onClose = { [weak self] in
            self?.close()
        }
        searchViewModel.onContentSizeChange = { [weak self] size in
            self?.resizeToContentSize(size, preserveTopEdge: true)
            // SwiftUI layout may settle over multiple frames; ensure we stay on-screen.
            DispatchQueue.main.async { self?.clampFrameToScreen() }
        }
        voiceController.onStateChange = { [weak self] state in
            switch state {
            case .idle:
                RealtimeInputLog.shared.recordVoiceState("idle")
            case .listening:
                RealtimeInputLog.shared.recordVoiceState("listening")
            case .transcribing:
                RealtimeInputLog.shared.recordVoiceState("transcribing")
            case .failed(let message):
                RealtimeInputLog.shared.recordVoiceState("failed \(message)")
            }
            self?.handleVoiceStateChange(state)
        }
        voiceController.onLevelChange = { [weak self] level in
            self?.searchViewModel.voiceLevel = level
        }
        voiceController.onPartialTranscript = { transcript in
            RealtimeInputLog.shared.recordSpeechPartial(transcript)
        }
        voiceController.onTranscript = { [weak self] transcript in
            guard let self else { return }
            self.cancelPendingRealtimeLogStop()
            let composedMessage = RealtimeInputLog.shared.finalizeSession(withFinalTranscript: transcript) ?? transcript
            self.searchViewModel.query = composedMessage
            self.searchViewModel.submitMessage(messageOverride: composedMessage)
        }

        searchViewModel.$isMinimalMode
            .sink { [weak self] _ in
                self?.updateGlassCornerRadius()
            }
            .store(in: &cancellables)

        searchViewModel.$hoveredElementFrame
            .sink { [weak self] frame in
                guard let self else { return }
                if self.isVisible {
                    self.highlightOverlayStore?.update(frame: frame)
                } else {
                    self.highlightOverlayStore?.clear()
                }
            }
            .store(in: &cancellables)
    }

    private func installFloatingSurface() {
        glassEffectView = NativeGlass.makeView(cornerRadius: currentGlassCornerRadius)

        restoreFloatingSurface()
    }

    private func restoreFloatingSurface() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        if let glass = glassEffectView {
            NativeGlass.attach(contentView: hostingView, to: glass)
            contentView = glass
        } else {
            contentView = hostingView
        }

        updateGlassCornerRadius()
    }

    private func updateGlassCornerRadius() {
        if let glass = glassEffectView {
            NativeGlass.updateCornerRadius(currentGlassCornerRadius, on: glass)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private static func normalizedContextText(_ text: String?) -> String? {
        guard let text else { return nil }
        if let colonRange = text.range(of: ": ") {
            return String(text[colonRange.upperBound...])
        }
        return text
    }

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
            if current is FocusedTextField.InputScrollView || current is NSTextView {
                return true
            }
            if current.enclosingScrollView is FocusedTextField.InputScrollView {
                return true
            }
            if current is NSScrollView { return true }
            v = current.superview
        }
        return false
    }

    var isTypingInputActive: Bool {
        guard isVisible, !searchViewModel.isCommandKeyMode else { return false }
        return isScrollOrTextInput(firstResponder as? NSView)
    }

    func hoverSnapshot(at mouseLocation: CGPoint) -> HoverSnapshot? {
        guard isVisible, frame.contains(mouseLocation) else { return nil }

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "This"
        let target = isTypingInputActive ? "text field" : "panel"
        let workingDirectoryURL = searchViewModel.currentSessionWorkingDirectoryURL ?? searchViewModel.hoveredWorkingDirectoryURL

        return HoverSnapshot(
            timestamp: Date(),
            processID: ProcessInfo.processInfo.processIdentifier,
            description: "\(appName) → \(target)",
            parts: [appName, target],
            selectedText: "",
            elementFrame: frame,
            windowFrame: frame,
            screenPoint: mouseLocation,
            fileSystemURL: nil,
            workingDirectoryURL: workingDirectoryURL
        )
    }

    func show(at point: NSPoint) {
        searchViewModel.query = ""
        isCursorFollowing = false
        restoreFloatingSurface()

        let fittingSize = normalizedFloatingBodySize(hostingView.fittingSize)
        setContentSize(fittingSize)

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

        // Query accessibility after panel is visible so the highlight overlay updates.
        // Re-order panel to front afterward since the highlight window uses orderFrontRegardless.
        searchViewModel.updateHoveredApp()
        orderFrontRegardless()

        // Dismiss on click outside (no mouse-move monitors — panel stays anchored)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, !self.isTerminalMode else { return }
            self.dismiss(restorePreviousFocus: false)
        }
    }

    func show() {
        searchViewModel.query = ""
        isCursorFollowing = true
        restoreFloatingSurface()

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

    private func prepareTaskWindow(centerWindow: Bool) {
        isTerminalMode = true
        isCursorFollowing = false
        removeAllMonitors()
        beginPersistentTaskIfNeeded()

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
        contentView = hostingView

        let chatSize = CGSize(width: 460, height: 200)
        setContentSize(chatSize)
        positionTaskWindow(
            previousOriginX: previousOriginX,
            previousTop: previousTop,
            centerWindow: centerWindow
        )
        // Re-establish key window status after the style mask change, which can
        // silently drop it (non-activating panel → normal titled window).
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        notifyTaskStateChanged()
    }

    private func prepareHeadlessTask() {
        isTerminalMode = true
        isCursorFollowing = false
        removeAllMonitors()
        beginPersistentTaskIfNeeded()
    }

    private func makeConversationManager() -> ClaudeProcessManager {
        let manager = ClaudeProcessManager()
        manager.onComplete = { [weak self] response in
            let completedEvents = manager.events
            manager.outputText = ""
            manager.events = []
            self?.searchViewModel.chatHistory.append(
                ChatMessage(
                    role: "assistant",
                    text: response,
                    events: completedEvents,
                    structuredUI: manager.structuredUIResponse
                )
            )
            if let sid = manager.sessionId {
                self?.searchViewModel.currentSessionId = sid
                self?.searchViewModel.hasStartedClaudeConversation = true
            }
            self?.saveChatSession()
            self?.onStreamingComplete?()
        }
        return manager
    }

    private func attachConversationManager(
        _ manager: ClaudeProcessManager,
        workingDirectoryURL: URL?
    ) {
        searchViewModel.claudeManager = manager
        searchViewModel.isChatMode = true
        searchViewModel.currentSessionWorkingDirectoryURL = workingDirectoryURL
        notifyTaskStateChanged()
    }

    private func currentInvocationSnapshot() -> ExternalFocusSnapshot? {
        if let liveSnapshot = ExternalFocusInspector.captureCurrent() {
            return liveSnapshot
        }
        if let recentQuickActionInvocationSnapshot {
            return recentQuickActionInvocationSnapshot
        }
        if let externalInvocationSnapshot {
            return externalInvocationSnapshot
        }

        let app = focusRestorationState?.app
            ?? focusRestorationState.flatMap { runningApplication(for: $0) }
        let windowTitle = focusRestorationState?.focusedWindow.flatMap {
            ExternalFocusInspector.stringAttribute("AXTitle", of: $0)
                ?? ExternalFocusInspector.stringAttribute(kAXTitleAttribute as String, of: $0)
        }
        return ExternalFocusSnapshot(
            appName: app?.localizedName,
            bundleIdentifier: app?.bundleIdentifier ?? focusRestorationState?.bundleIdentifier,
            processIdentifier: app?.processIdentifier ?? focusRestorationState?.processIdentifier,
            windowTitle: windowTitle
        )
    }

    private func beginPreClaudeTask(
        rawPrompt: String,
        claudeMessage: String,
        workingDirectoryURL: URL?,
        userAlreadyRecorded: Bool,
        screenshotProvider: @escaping () -> (URL?, String)
    ) {
        if !userAlreadyRecorded {
            searchViewModel.chatHistory.append(ChatMessage(role: "user", text: rawPrompt))
            searchViewModel.query = ""
        }

        let manager = makeConversationManager()
        attachConversationManager(manager, workingDirectoryURL: workingDirectoryURL)
        manager.beginRouting()

        let request = QuickActionRequest(
            prompt: rawPrompt,
            claudePrompt: claudeMessage,
            surface: quickActionSurface,
            hoveredParts: searchViewModel.hoveredParts,
            hoveredFileURL: searchViewModel.hoveredFileSystemURL,
            hoveredWorkingDirectoryURL: workingDirectoryURL ?? searchViewModel.hoveredWorkingDirectoryURL,
            allowsDeicticFileTarget: searchViewModel.allowsDeicticFileTarget,
            selectedText: searchViewModel.selectedText,
            invocationSnapshot: currentInvocationSnapshot()
        )

        let outcome = quickActionCoordinator?.route(request) ?? .fallback(claudeMessage)
        switch outcome {
        case .local(let result):
            if let snapshot = ExternalFocusInspector.captureCurrent() ?? result.resultingInvocationSnapshot {
                recentQuickActionInvocationSnapshot = snapshot
            }
            manager.completeLocally(result)
        case .fallback(let fallbackMessage):
            let outboundMessage = searchViewModel.bootstrapClaudeMessageForFirstClaudeTurn(
                currentUserText: rawPrompt,
                claudePrompt: fallbackMessage
            )
            searchViewModel.hasStartedClaudeConversation = true
            let (screenshotURL, _) = screenshotProvider()
            manager.startClaude(
                message: outboundMessage,
                screenshotURL: screenshotURL,
                workingDirectoryURL: workingDirectoryURL
            )
        }
    }

    func transitionToTerminal(
        message: String,
        screenshotURL: URL? = nil,
        workingDirectoryURL: URL? = nil,
        centerWindow: Bool = false,
        restoreOnly: Bool = false
    ) {
        prepareTaskWindow(centerWindow: centerWindow)

        if restoreOnly {
            // Restoring a persisted session — chat history is already populated
            searchViewModel.query = ""
            searchViewModel.claudeManager = nil
            searchViewModel.isChatMode = true
            searchViewModel.currentSessionWorkingDirectoryURL = workingDirectoryURL
            return
        }

        let rawPrompt = searchViewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let manager = makeConversationManager()
        attachConversationManager(manager, workingDirectoryURL: workingDirectoryURL)
        searchViewModel.chatHistory.append(ChatMessage(role: "user", text: rawPrompt))
        searchViewModel.query = ""

        searchViewModel.hasStartedClaudeConversation = true
        manager.startClaude(
            message: message,
            screenshotURL: screenshotURL,
            workingDirectoryURL: workingDirectoryURL
        )
    }

    func startTaskFromMenu(query: String) {
        searchViewModel.configureHomeFolderContext()
        quickActionSurface = .commandMenu
        searchViewModel.query = query
        transitionToTerminalWithRouting(
            rawPrompt: query,
            claudeMessage: searchViewModel.buildContextMessage(),
            workingDirectoryURL: searchViewModel.hoveredWorkingDirectoryURL,
            centerWindow: true,
            screenshotProvider: { [weak self] in
                self?.searchViewModel.captureFullScreenScreenshot() ?? (nil, "")
            }
        )
    }

    func startHeadless(
        message: String,
        screenshotURL: URL? = nil,
        workingDirectoryURL: URL? = nil
    ) {
        prepareHeadlessTask()

        let rawPrompt = searchViewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let manager = makeConversationManager()
        attachConversationManager(manager, workingDirectoryURL: workingDirectoryURL)
        searchViewModel.chatHistory.append(ChatMessage(role: "user", text: rawPrompt))
        searchViewModel.query = ""

        searchViewModel.hasStartedClaudeConversation = true
        manager.startClaude(
            message: message,
            screenshotURL: screenshotURL,
            workingDirectoryURL: workingDirectoryURL
        )
    }

    func startTaskFromMenuHeadless(query: String) {
        searchViewModel.configureHomeFolderContext()
        quickActionSurface = .commandMenu
        searchViewModel.query = query
        startHeadlessWithRouting(
            rawPrompt: query,
            claudeMessage: searchViewModel.buildContextMessage(),
            workingDirectoryURL: searchViewModel.hoveredWorkingDirectoryURL,
            screenshotProvider: { [weak self] in
                self?.searchViewModel.captureFullScreenScreenshot() ?? (nil, "")
            }
        )
    }

    func transitionToTerminalWithRouting(
        rawPrompt: String,
        claudeMessage: String,
        workingDirectoryURL: URL?,
        centerWindow: Bool = false,
        screenshotProvider: (() -> (URL?, String))? = nil
    ) {
        prepareTaskWindow(centerWindow: centerWindow)
        beginPreClaudeTask(
            rawPrompt: rawPrompt,
            claudeMessage: claudeMessage,
            workingDirectoryURL: workingDirectoryURL,
            userAlreadyRecorded: false,
            screenshotProvider: screenshotProvider ?? { [weak self] in
                self?.searchViewModel.captureCurrentScreenScreenshot() ?? (nil, "")
            }
        )
    }

    func startHeadlessWithRouting(
        rawPrompt: String,
        claudeMessage: String,
        workingDirectoryURL: URL?,
        screenshotProvider: (() -> (URL?, String))? = nil
    ) {
        prepareHeadlessTask()
        beginPreClaudeTask(
            rawPrompt: rawPrompt,
            claudeMessage: claudeMessage,
            workingDirectoryURL: workingDirectoryURL,
            userAlreadyRecorded: false,
            screenshotProvider: screenshotProvider ?? { [weak self] in
                self?.searchViewModel.captureCurrentScreenScreenshot() ?? (nil, "")
            }
        )
    }

    private func routeChatTurnBeforeClaude(
        rawPrompt: String,
        claudeMessage: String,
        workingDirectoryURL: URL?
    ) -> Bool {
        guard !searchViewModel.hasStartedClaudeConversation else { return false }
        beginPreClaudeTask(
            rawPrompt: rawPrompt,
            claudeMessage: claudeMessage,
            workingDirectoryURL: workingDirectoryURL,
            userAlreadyRecorded: true,
            screenshotProvider: { [weak self] in
                self?.searchViewModel.captureCurrentScreenScreenshot() ?? (nil, "")
            }
        )
        return true
    }

    func restoreHeadless(workingDirectoryURL: URL?) {
        isTerminalMode = true
        isCursorFollowing = false
        removeAllMonitors()
        beginPersistentTaskIfNeeded()

        searchViewModel.query = ""
        searchViewModel.claudeManager = nil
        searchViewModel.isChatMode = true
        searchViewModel.currentSessionWorkingDirectoryURL = workingDirectoryURL
    }

    // MARK: - Task Icon Mode

    func startTaskIconMode(
        rawPrompt: String,
        claudeMessage: String,
        workingDirectoryURL: URL?
    ) {
        isTaskIconMode = true
        prepareHeadlessTask()

        // Capture the CGWindowID of the window under the cursor for tracking
        captureTrackedWindow()

        // Use the shared routing/task setup
        beginPreClaudeTask(
            rawPrompt: rawPrompt,
            claudeMessage: claudeMessage,
            workingDirectoryURL: workingDirectoryURL,
            userAlreadyRecorded: false,
            screenshotProvider: { [weak self] in
                self?.searchViewModel.captureCurrentScreenScreenshot() ?? (nil, "")
            }
        )

        // Animate to minimal icon
        searchViewModel.isMinimalMode = true
        searchViewModel.isTaskIconMode = true

        let iconSize: CGFloat = 36
        let anchorTop = frame.maxY
        let iconOrigin = NSPoint(
            x: frame.minX,
            y: anchorTop - iconSize
        )
        taskIconAnchorOrigin = iconOrigin

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(
                NSRect(origin: iconOrigin, size: CGSize(width: iconSize, height: iconSize)),
                display: true
            )
        }

        // Start window-follow timer
        startTaskIconFollowTimer()

        // Install hover monitors
        taskIconHoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleTaskIconMouseMove()
        }
        taskIconLocalHoverMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleTaskIconMouseMove()
            return event
        }

        installEscapeMonitor()
    }

    private func captureTrackedWindow() {
        let pid = searchViewModel.hoveredAppPID
        guard pid != 0 else {
            taskIconWindowID = nil
            taskIconWindowOffset = nil
            return
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            taskIconWindowID = nil
            taskIconWindowOffset = nil
            return
        }

        // Find the frontmost window belonging to the hovered app
        let mouseLocation = NSEvent.mouseLocation
        let screenHeight = NSScreen.main?.frame.height ?? 0

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID] as? pid_t,
                  ownerPID == pid,
                  let windowID = windowInfo[kCGWindowNumber] as? CGWindowID,
                  let boundsDict = windowInfo[kCGWindowBounds] as? [String: CGFloat],
                  let wx = boundsDict["X"],
                  let wy = boundsDict["Y"],
                  let ww = boundsDict["Width"],
                  let wh = boundsDict["Height"],
                  ww > 0, wh > 0 else { continue }

            // CGWindowList uses top-left origin; convert to bottom-left (AppKit)
            let windowOrigin = CGPoint(x: wx, y: screenHeight - wy - wh)
            let windowFrame = CGRect(origin: windowOrigin, size: CGSize(width: ww, height: wh))

            // Check if mouse is within this window
            if windowFrame.contains(mouseLocation) {
                taskIconWindowID = windowID
                taskIconWindowOffset = CGPoint(
                    x: frame.origin.x - windowOrigin.x,
                    y: frame.origin.y - windowOrigin.y
                )
                return
            }
        }

        // No matching window found — stay fixed
        taskIconWindowID = nil
        taskIconWindowOffset = nil
    }

    private func startTaskIconFollowTimer() {
        taskIconFollowTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateTaskIconPosition()
        }
    }

    private func updateTaskIconPosition() {
        guard let windowID = taskIconWindowID, let offset = taskIconWindowOffset else { return }

        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let windowList = CGWindowListCopyWindowInfo(options, windowID) as? [[CFString: Any]],
              let windowInfo = windowList.first,
              let boundsDict = windowInfo[kCGWindowBounds] as? [String: CGFloat],
              let wx = boundsDict["X"],
              let wy = boundsDict["Y"],
              let wh = boundsDict["Height"] else {
            // Window not found — keep icon at last position
            return
        }

        let screenHeight = NSScreen.main?.frame.height ?? 0

        // Check if window is on screen
        let isOnScreen = windowInfo[kCGWindowIsOnscreen as CFString] as? Bool ?? true
        if !isOnScreen {
            if isVisible { orderOut(nil) }
            return
        } else {
            if !isVisible { orderFront(nil) }
        }

        // Reposition icon relative to tracked window
        let windowOrigin = CGPoint(x: wx, y: screenHeight - wy - wh)
        let newAnchor = NSPoint(x: windowOrigin.x + offset.x, y: windowOrigin.y + offset.y)
        taskIconAnchorOrigin = newAnchor
        if !searchViewModel.isTaskIconHovered {
            setFrameOrigin(newAnchor)
        } else {
            // When hovered/expanded, shift the expanded frame to track the window
            expandTaskIconForHover()
        }
    }

    private func handleTaskIconMouseMove() {
        guard isTaskIconMode else { return }
        let mouseLocation = NSEvent.mouseLocation
        let cursorOver = isCursorOverPanel(mouseLocation)

        if cursorOver && !searchViewModel.isTaskIconHovered {
            searchViewModel.isTaskIconHovered = true
            // Expand panel to fit status text
            DispatchQueue.main.async { [weak self] in
                self?.expandTaskIconForHover()
            }
        } else if !cursorOver && searchViewModel.isTaskIconHovered {
            searchViewModel.isTaskIconHovered = false
            // Shrink back to icon
            collapseTaskIconFromHover()
        }
    }

    private func expandTaskIconForHover() {
        guard isTaskIconMode, searchViewModel.isTaskIconHovered,
              let anchor = taskIconAnchorOrigin else { return }
        let fittingSize = hostingView.fittingSize
        let newWidth = max(fittingSize.width, 36)
        let newHeight = max(fittingSize.height, 36)

        // Determine expansion direction based on screen position
        let screen = self.screen ?? NSScreen.main
        let screenMidX = screen?.visibleFrame.midX ?? anchor.x

        var newOrigin = anchor
        if anchor.x + 18 > screenMidX {
            // Closer to right edge — expand leftward (right edge stays at anchor right edge)
            newOrigin.x = (anchor.x + 36) - newWidth
        }
        // Closer to left edge — expand rightward (left edge stays at anchor)
        // Keep top edge aligned
        newOrigin.y = (anchor.y + 36) - newHeight

        setFrame(NSRect(origin: newOrigin, size: CGSize(width: newWidth, height: newHeight)), display: true)
    }

    private func collapseTaskIconFromHover() {
        guard isTaskIconMode, let anchor = taskIconAnchorOrigin else { return }
        let iconSize: CGFloat = 36
        setFrame(NSRect(origin: anchor, size: CGSize(width: iconSize, height: iconSize)), display: true)
    }

    func transitionTaskIconToCommandMenu() {
        stopTaskIconFollowTimer()
        removeTaskIconMonitors()
        orderOut(nil)
        // Call callback before resetting state so it can detect task icon mode
        onTransitionToCommandMenu?(self)
        isTaskIconMode = false
        searchViewModel.isTaskIconMode = false
        searchViewModel.isTaskIconHovered = false
    }

    private func stopTaskIconFollowTimer() {
        taskIconFollowTimer?.invalidate()
        taskIconFollowTimer = nil
    }

    private func removeTaskIconMonitors() {
        if let m = taskIconHoverMonitor { NSEvent.removeMonitor(m) }
        if let m = taskIconLocalHoverMonitor { NSEvent.removeMonitor(m) }
        taskIconHoverMonitor = nil
        taskIconLocalHoverMonitor = nil
    }

    func reopenPersistentTaskWindow() {
        guard preservesTaskHistory else { return }
        prepareForTextInputFocus()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        notifyTaskStateChanged()
    }

    func destroyPersistentTaskWindow() {
        isDestroyingTaskWindow = true
        close()
    }

    private func positionTaskWindow(
        previousOriginX: CGFloat,
        previousTop: CGFloat,
        centerWindow: Bool
    ) {
        if centerWindow {
            let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screen ?? NSScreen.main
            let visibleFrame = targetScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let origin = NSPoint(
                x: visibleFrame.midX - frame.width / 2,
                y: visibleFrame.midY - frame.height / 2
            )
            setFrameOrigin(origin)
            return
        }

        // Preserve position of the top-left corner, clamped to screen.
        var nextOrigin = NSPoint(x: previousOriginX, y: previousTop - frame.height)
        if let scr = screen ?? NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
            let sf = scr.visibleFrame
            nextOrigin.x = max(sf.minX, min(nextOrigin.x, sf.maxX - frame.width))
            nextOrigin.y = max(sf.minY, min(nextOrigin.y, sf.maxY - frame.height))
        }
        setFrameOrigin(nextOrigin)
    }

    private func beginPersistentTaskIfNeeded() {
        let now = Date()

        if !preservesTaskHistory {
            preservesTaskHistory = true
            taskStartedAt = now
            onPersistentTaskStarted?(self)
        }

        taskCompletedAt = nil
        taskLastActivityAt = now
        notifyTaskStateChanged()
    }

    func saveChatSession() {
        guard preservesTaskHistory, !searchViewModel.chatHistory.isEmpty else { return }

        let id = persistedSessionId ?? UUID().uuidString
        persistedSessionId = id

        let messages = searchViewModel.chatHistory.map {
            PersistedMessage(role: $0.role, text: $0.text, structuredUI: $0.structuredUI)
        }

        let session = PersistedChatSession(
            id: id,
            sessionId: searchViewModel.currentSessionId,
            title: taskDisplayTitle,
            subtitle: taskDisplaySubtitle,
            messages: messages,
            startedAt: taskStartedAt ?? Date(),
            completedAt: taskCompletedAt,
            lastActivityAt: taskLastActivityAt ?? Date(),
            workingDirectoryPath: searchViewModel.currentSessionWorkingDirectoryURL?.path
        )

        ChatSessionStore.shared.save(session)
    }

    private func markTaskActivity(completed: Bool = false) {
        guard preservesTaskHistory else { return }

        let now = Date()
        taskLastActivityAt = now
        taskCompletedAt = completed ? now : nil
        notifyTaskStateChanged()
    }

    private func configureClaudeManager(_ manager: ClaudeProcessManager?) {
        manager?.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                self?.handleManagerStatusChange(status)
            }
        }
        manager?.onToolActivity = { [weak self] intent in
            DispatchQueue.main.async {
                self?.onGhostCursorIntent?(intent)
            }
        }
    }

    private func handleManagerStatusChange(_ status: StreamStatus) {
        guard preservesTaskHistory else { return }

        switch status {
        case .routing:
            taskCompletedAt = nil
            taskLastActivityAt = Date()
        case .waiting:
            lastCompletedCommandMenuAction = .reveal
            taskCompletedAt = nil
            taskLastActivityAt = Date()
        case .streaming:
            lastCompletedCommandMenuAction = .reveal
            taskCompletedAt = nil
            taskLastActivityAt = Date()
            onStreamingBegan?()
        case .done, .error:
            lastCompletedCommandMenuAction = searchViewModel.claudeManager?.completionAction ?? .reveal
            let now = Date()
            taskCompletedAt = now
            taskLastActivityAt = now
            saveChatSession()
        }

        notifyTaskStateChanged()
    }

    private func notifyTaskStateChanged() {
        onTaskStateChanged?(self)
    }

    private func positionAtCursor() {
        positionAtCursor(using: NSEvent.mouseLocation)
    }

    private func positionAtCursor(using mouse: NSPoint) {
        guard !isTerminalMode else { return }
        let fittingSize = normalizedFloatingBodySize(hostingView.fittingSize)
        setContentSize(fittingSize)

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
        let normalizedSize = normalizedFloatingBodySize(size)
        guard normalizedSize.width > 0, normalizedSize.height > 0 else { return }
        guard abs(normalizedSize.width - lastReportedContentSize.width) > 0.5 ||
              abs(normalizedSize.height - lastReportedContentSize.height) > 0.5 else { return }
        lastReportedContentSize = normalizedSize

        guard isVisible else { return }
        let previousTop = frame.maxY
        let previousOriginX = frame.minX

        setContentSize(normalizedSize)

        var nextOrigin = NSPoint(
            x: previousOriginX,
            y: preserveTopEdge ? previousTop - frame.height : frame.minY
        )
        if let screen = screen ?? NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            nextOrigin.x = max(visibleFrame.minX, min(nextOrigin.x, visibleFrame.maxX - frame.width))
            nextOrigin.y = max(visibleFrame.minY, min(nextOrigin.y, visibleFrame.maxY - frame.height))
        }

        setFrameOrigin(nextOrigin)
    }

    /// Ensures the panel frame is fully within the visible area of its screen.
    private func clampFrameToScreen() {
        guard isVisible, !isTerminalMode else { return }
        guard let screen = screen ?? NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main else { return }
        let sf = screen.visibleFrame
        var origin = frame.origin
        origin.x = max(sf.minX, min(origin.x, sf.maxX - frame.width))
        origin.y = max(sf.minY, min(origin.y, sf.maxY - frame.height))
        if origin != frame.origin {
            setFrameOrigin(origin)
        }
    }

    // MARK: - Command key mode

    /// Called when the invoke hotkey is pressed. Shows a minimal icon indicator immediately,
    /// then expands to the full panel on the first cursor move.
    func startCommandKeyMode(with modifierFlags: NSEvent.ModifierFlags) {
        invokeHoldBehavior = .cursorFollow
        isCommandKeyHeld = true
        currentModifierFlags = modifierFlags
        searchViewModel.isCommandKeyMode = true
        searchViewModel.isMinimalMode = true
        searchViewModel.query = ""
        isCommandKeyVisible = false
        isCursorFollowing = true

        // Show the indicator right away at the current cursor position
        searchViewModel.updateHoveredApp()
        positionAtCursor()
        orderFront(nil)
        updateModifierFlags(modifierFlags)

        commandKeyMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            if !self.isCommandKeyVisible {
                self.isCommandKeyVisible = true
                self.searchViewModel.isMinimalMode = false
            }
            self.handleCommandKeyMouseMove()
        }

        installEscapeMonitor()
    }

    /// Called when the invoke hotkey is released. Anchors the panel and shows the input row.
    /// If the panel was never shown (cursor didn't move), discard silently.
    func endInvokeHoldMode() {
        switch invokeHoldBehavior {
        case .cursorFollow:
            endCursorFollowInvokeHoldMode()
        case .anchoredInput:
            stopVoiceModeIfNeeded()
            invokeHoldBehavior = nil
        case .pinnedFollow:
            // Pinned mode doesn't end on key release — it persists until Esc
            break
        case nil:
            break
        }
    }

    private func endCursorFollowInvokeHoldMode() {
        if let m = commandKeyMouseMonitor { NSEvent.removeMonitor(m); commandKeyMouseMonitor = nil }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        isCursorFollowing = false

        guard isCommandKeyVisible else {
            voiceController.cancel()
            dismiss(restorePreviousFocus: false)
            return
        }

        stopVoiceModeIfNeeded()

        // Record where the cursor is now — this becomes the apex of the safe triangle.
        safeTriangleApex = NSEvent.mouseLocation

        // Show input row if it was hidden
        if searchViewModel.isCommandKeyMode {
            searchViewModel.isCommandKeyMode = false
            prepareForTextInputFocus()
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            // After SwiftUI settles the wider/taller layout, ensure the panel
            // hasn't expanded off-screen (e.g. cursor was near a screen edge).
            DispatchQueue.main.async { [weak self] in
                self?.clampFrameToScreen()
            }
        }

        // Dismiss when cursor leaves the panel and its safe triangle zone.
        // The safe triangle extends from the original cursor position to the
        // panel corners, making it forgiving to move diagonally toward the panel.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self,
                  !InvokeHotKey.stored().isPressed(in: NSEvent.modifierFlags),
                  !self.searchViewModel.isChatMode else { return }
            if !self.isCursorInSafeZone(NSEvent.mouseLocation) {
                self.dismiss()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self,
                  !InvokeHotKey.stored().isPressed(in: NSEvent.modifierFlags),
                  !self.searchViewModel.isChatMode else { return event }
            if !self.isCursorInSafeZone(NSEvent.mouseLocation) {
                self.dismiss()
            }
            return event
        }
        invokeHoldBehavior = nil
    }

    /// Re-enter cursor-following on an already-visible panel.
    /// Hides the input row only if no text has been typed yet.
    func restartCommandKeyMode(with modifierFlags: NSEvent.ModifierFlags) {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        if let m = commandKeyMouseMonitor { NSEvent.removeMonitor(m); commandKeyMouseMonitor = nil }
        cancelPinnedPauseTimer()
        pinnedInputVisible = false

        isCommandKeyHeld = true
        currentModifierFlags = modifierFlags
        invokeHoldBehavior = .cursorFollow
        isCommandKeyVisible = true
        isCursorFollowing = true
        if searchViewModel.query.isEmpty {
            searchViewModel.isCommandKeyMode = true
        }
        updateModifierFlags(modifierFlags)

        // Immediately reposition at the current cursor location
        positionAtCursor()

        // Global monitor fires when another app is frontmost; local monitor fires when we are.
        commandKeyMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            self.handleCommandKeyMouseMove()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            guard let self else { return event }
            self.handleCommandKeyMouseMove()
            return event
        }

        installEscapeMonitor()
    }

    func startAnchoredVoiceMode(with modifierFlags: NSEvent.ModifierFlags) {
        invokeHoldBehavior = .anchoredInput
        isCommandKeyHeld = true
        currentModifierFlags = modifierFlags
        isCursorFollowing = false
        searchViewModel.isMinimalMode = false
        searchViewModel.isCommandKeyMode = false
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        syncVoiceModeWithCurrentModifiers()
    }

    private func handleCommandKeyMouseMove() {
        // Detect missed invoke hotkey releases (e.g., consumed by system).
        if !InvokeHotKey.stored().isPressed(in: NSEvent.modifierFlags) {
            isCommandKeyHeld = false
            onCommandKeyDropped?()
            endInvokeHoldMode()
            return
        }

        let mouseLocation = NSEvent.mouseLocation
        positionAtCursor(using: mouseLocation)
        searchViewModel.updateHoveredApp()
    }

    // MARK: - Escape key monitor

    private func installEscapeMonitor() {
        if escapeKeyMonitor != nil { return }
        escapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return } // 53 = Escape
            self?.dismiss(restorePreviousFocus: true)
        }
    }

    private func removeEscapeMonitor() {
        if let m = escapeKeyMonitor { NSEvent.removeMonitor(m); escapeKeyMonitor = nil }
    }

    // MARK: - Pinned follow mode (double-tap invoke key)

    /// Enters hands-free cursor-follow mode. The panel follows the cursor without
    /// needing to hold the invoke key. If autovoice is enabled, voice mode starts
    /// immediately and persists until the user presses the invoke key (to send) or
    /// Escape (to cancel). Without voice, pausing on an object for >1s shows the
    /// text input; moving away hides it (unless text has been typed).
    func startPinnedFollowMode(with modifierFlags: NSEvent.ModifierFlags) {
        invokeHoldBehavior = .pinnedFollow
        isCommandKeyHeld = false
        currentModifierFlags = modifierFlags
        searchViewModel.isCommandKeyMode = true
        searchViewModel.isMinimalMode = false
        searchViewModel.query = ""
        isCommandKeyVisible = true
        isCursorFollowing = true
        pinnedInputVisible = false

        searchViewModel.updateHoveredApp()
        positionAtCursor()
        orderFront(nil)

        // Start voice if autovoice is on or shift is held
        if AppSettings.autoVoiceEnabled || modifierFlags.contains(.shift) {
            voiceController.start()
        }

        commandKeyMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handlePinnedMouseMove()
        }
        pinnedLocalMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handlePinnedMouseMove()
            return event
        }

        installEscapeMonitor()
    }

    private func handlePinnedMouseMove() {
        guard invokeHoldBehavior == .pinnedFollow else { return }

        let mouseLocation = NSEvent.mouseLocation

        // If voice has actually transcribed speech, stay in voice mode — just follow
        if voiceController.hasTranscribedSpeech {
            positionAtCursor(using: mouseLocation)
            searchViewModel.updateHoveredApp()
            return
        }

        let cursorOverPanel = isCursorOverPanel(mouseLocation)

        if pinnedInputVisible {
            // Input is showing. If cursor is over panel, stay anchored.
            // If cursor moves away, follow cursor (keep text if any).
            if !cursorOverPanel {
                // Resume following
                if searchViewModel.query.isEmpty {
                    // No text typed — hide input, back to command key mode
                    pinnedInputVisible = false
                    searchViewModel.isCommandKeyMode = true
                }
                positionAtCursor(using: mouseLocation)
                searchViewModel.updateHoveredApp()
                resetPinnedPauseTimer()
            }
            // If cursor is over panel, do nothing — panel stays anchored
        } else {
            // Input not showing — follow cursor and manage pause timer
            positionAtCursor(using: mouseLocation)
            searchViewModel.updateHoveredApp()
            resetPinnedPauseTimer()
        }
    }

    private func resetPinnedPauseTimer() {
        cancelPinnedPauseTimer()

        // Don't start pause timer if voice has transcribed speech
        guard !voiceController.hasTranscribedSpeech else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.invokeHoldBehavior == .pinnedFollow,
                  !self.voiceController.hasTranscribedSpeech else { return }
            self.showPinnedInput()
        }
        pinnedPauseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func cancelPinnedPauseTimer() {
        pinnedPauseWorkItem?.cancel()
        pinnedPauseWorkItem = nil
    }

    private func showPinnedInput() {
        guard invokeHoldBehavior == .pinnedFollow else { return }
        // Stop voice if it's listening but hasn't transcribed anything
        if searchViewModel.isVoiceModeActive && !voiceController.hasTranscribedSpeech {
            voiceController.cancel()
        }
        pinnedInputVisible = true
        searchViewModel.isCommandKeyMode = false
        prepareForTextInputFocus()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            self?.clampFrameToScreen()
        }
    }

    private func isCursorOverPanel(_ cursor: NSPoint) -> Bool {
        let padding: CGFloat = 8
        let paddedFrame = frame.insetBy(dx: -padding, dy: -padding)
        return paddedFrame.contains(cursor)
    }

    /// Called when invoke key is pressed while in pinned-follow mode.
    /// If voice is active, this sends the voice message. If nothing has been
    /// spoken or typed, dismiss the panel.
    func handleInvokeKeyInPinnedMode() {
        guard invokeHoldBehavior == .pinnedFollow else { return }

        if searchViewModel.voiceState == .listening || searchViewModel.voiceState == .transcribing {
            // Voice is active — send it
            voiceController.stop()
        } else if searchViewModel.query.isEmpty {
            // Nothing spoken or typed — dismiss
            dismiss(restorePreviousFocus: true)
        }
        // If text has been typed, invoke key is a no-op (use Enter to submit, Esc to dismiss)
    }

    /// Returns true when the cursor is inside the panel frame (with padding) or
    /// inside a triangular "safe zone" that extends from the original cursor
    /// position (apex) to the two closest corners of the panel.  This prevents
    /// the panel from dismissing when the user moves diagonally toward it.
    private func isCursorInSafeZone(_ cursor: NSPoint) -> Bool {
        let padding: CGFloat = 8
        let paddedFrame = frame.insetBy(dx: -padding, dy: -padding)
        if paddedFrame.contains(cursor) { return true }

        guard let apex = safeTriangleApex else { return false }

        // Build a triangle from the apex to the two panel corners nearest to it.
        let corners = [
            NSPoint(x: frame.minX, y: frame.minY),
            NSPoint(x: frame.maxX, y: frame.minY),
            NSPoint(x: frame.maxX, y: frame.maxY),
            NSPoint(x: frame.minX, y: frame.maxY),
        ]

        // Try all corner pairs and keep the triangle that contains the panel center.
        let panelCenter = NSPoint(x: frame.midX, y: frame.midY)
        for i in 0..<corners.count {
            for j in (i + 1)..<corners.count {
                let a = apex, b = corners[i], c = corners[j]
                if pointInTriangle(panelCenter, a, b, c) {
                    // Add padding by expanding the triangle slightly
                    let expandedB = expandPoint(b, from: a, by: padding)
                    let expandedC = expandPoint(c, from: a, by: padding)
                    if pointInTriangle(cursor, a, expandedB, expandedC) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func expandPoint(_ point: NSPoint, from origin: NSPoint, by amount: CGFloat) -> NSPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let length = hypot(dx, dy)
        guard length > 0 else { return point }
        return NSPoint(
            x: point.x + (dx / length) * amount,
            y: point.y + (dy / length) * amount
        )
    }

    private func pointInTriangle(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint, _ c: NSPoint) -> Bool {
        let d1 = sign(p, a, b)
        let d2 = sign(p, b, c)
        let d3 = sign(p, c, a)
        let hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0)
        let hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0)
        return !(hasNeg && hasPos)
    }

    private func sign(_ p1: NSPoint, _ p2: NSPoint, _ p3: NSPoint) -> CGFloat {
        (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
    }

    private func removeAllMonitors() {
        for monitor in [
            globalMouseMonitor,
            localMouseMonitor,
            globalClickMonitor,
            commandKeyMouseMonitor,
            dragStartMonitor,
            escapeKeyMonitor,
            pinnedLocalMouseMonitor
        ].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        globalClickMonitor = nil
        commandKeyMouseMonitor = nil
        dragStartMonitor = nil
        escapeKeyMonitor = nil
        pinnedLocalMouseMonitor = nil
        cancelPendingDrag()
        cancelPinnedPauseTimer()
        stopTaskIconFollowTimer()
        removeTaskIconMonitors()
    }

    override func close() {
        if preservesTaskHistory && (isTerminalMode || isTaskIconMode) && !isDestroyingTaskWindow {
            hidePersistentTaskWindow(restorePreviousFocus: shouldRestoreFocusOnClose)
            return
        }

        let shouldRestoreFocus = shouldRestoreFocusOnClose
        let restorationState = focusRestorationState
        shouldRestoreFocusOnClose = true
        focusRestorationState = nil
        isDestroyingTaskWindow = false

        saveChatSession()
        removeAllMonitors()
        cancelPendingRealtimeLogStop()
        RealtimeInputLog.shared.stopSession()
        voiceController.cancel()
        super.close()
        // Restore panel appearance for potential reuse
        if isTerminalMode {
            styleMask = [.borderless, .nonactivatingPanel]
            level = .screenSaver
            restoreFloatingSurface()
        }
        highlightOverlayStore?.clear()
        searchViewModel.query = ""
        searchViewModel.isChatMode = false
        searchViewModel.isCommandKeyMode = false
        searchViewModel.isMinimalMode = false
        searchViewModel.isTaskIconMode = false
        searchViewModel.isTaskIconHovered = false
        searchViewModel.voiceState = .idle
        searchViewModel.voiceLevel = 0
        searchViewModel.chatHistory = []
        searchViewModel.claudeManager = nil
        searchViewModel.currentSessionId = nil
        lastReportedContentSize = .zero
        isTerminalMode = false
        isTaskIconMode = false
        taskIconWindowID = nil
        taskIconWindowOffset = nil
        taskIconAnchorOrigin = nil
        isCommandKeyVisible = false
        isCursorFollowing = false
        invokeHoldBehavior = nil
        pinnedInputVisible = false
        safeTriangleApex = nil
        currentModifierFlags = []
        isCommandKeyHeld = false
        isRightClickInvoked = false
        preservesTaskHistory = false
        taskStartedAt = nil
        taskCompletedAt = nil
        taskLastActivityAt = nil

        if shouldRestoreFocus {
            restoreFocus(using: restorationState)
        }

        onPanelDestroyed?(self)
    }

    // Handle Escape: stop streaming if active, otherwise close
    override func mouseDown(with event: NSEvent) {
        if isTaskIconMode {
            transitionTaskIconToCommandMenu()
            return
        }
        super.mouseDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if let manager = searchViewModel.claudeManager,
           manager.status.isActive {
            manager.stop()
        } else {
            close()
        }
    }

    func dismiss(restorePreviousFocus: Bool = true) {
        shouldRestoreFocusOnClose = restorePreviousFocus
        close()
    }

    private func hidePersistentTaskWindow(restorePreviousFocus: Bool) {
        let restorationState = focusRestorationState
        focusRestorationState = nil
        shouldRestoreFocusOnClose = true

        removeAllMonitors()
        cancelPendingRealtimeLogStop()
        RealtimeInputLog.shared.stopSession()
        voiceController.cancel()
        orderOut(nil)
        isCommandKeyVisible = false
        isCursorFollowing = false
        invokeHoldBehavior = nil
        pinnedInputVisible = false
        safeTriangleApex = nil
        currentModifierFlags = []
        isCommandKeyHeld = false
        isRightClickInvoked = false
        notifyTaskStateChanged()

        if restorePreviousFocus {
            restoreFocus(using: restorationState)
        }
    }

    func updateModifierFlags(_ modifierFlags: NSEvent.ModifierFlags) {
        currentModifierFlags = modifierFlags
        syncVoiceModeWithCurrentModifiers()
    }

    private func startVoiceModeIfNeeded() {
        guard isVisible,
              isCommandKeyHeld,
              canUseVoiceInputDuringInvokeHold,
              !isActivelyStreamingResponse,
              !searchViewModel.isVoiceModeActive else { return }

        voiceController.start()
    }

    private func syncVoiceModeWithCurrentModifiers() {
        guard isVisible,
              isCommandKeyHeld,
              canUseVoiceInputDuringInvokeHold,
              !isActivelyStreamingResponse else { return }

        guard AppSettings.autoVoiceEnabled || currentModifierFlags.contains(.shift) else {
            cancelVoiceModeIfNeeded()
            return
        }

        startVoiceModeIfNeeded()
    }

    private func cancelVoiceModeIfNeeded() {
        switch searchViewModel.voiceState {
        case .listening, .idle:
            voiceController.cancel()
        case .transcribing, .failed:
            break
        }
    }

    private func stopVoiceModeIfNeeded() {
        switch searchViewModel.voiceState {
        case .listening:
            voiceController.stop()
        case .idle:
            // Voice start may still be pending (async permission/setup) — cancel it
            voiceController.cancel()
        case .transcribing, .failed:
            break
        }
    }

    private func handleVoiceStateChange(_ state: VoiceDictationController.State) {
        switch state {
        case .idle:
            searchViewModel.voiceState = .idle
            searchViewModel.voiceLevel = 0
            if !isCommandKeyHeld {
                scheduleRealtimeLogStopIfNeeded()
            }
        case .listening:
            cancelPendingRealtimeLogStop()
            searchViewModel.voiceState = .listening
        case .transcribing:
            cancelPendingRealtimeLogStop()
            searchViewModel.voiceState = .transcribing
            searchViewModel.voiceLevel = 0
        case .failed(let message):
            searchViewModel.voiceState = .failed(message)
            searchViewModel.voiceLevel = 0
            if !isCommandKeyHeld {
                RealtimeInputLog.shared.stopSession()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.searchViewModel.voiceState == .failed(message) else { return }
                self.searchViewModel.voiceState = .idle
            }
        }
    }

    private func scheduleRealtimeLogStopIfNeeded() {
        cancelPendingRealtimeLogStop()

        let workItem = DispatchWorkItem {
            RealtimeInputLog.shared.stopSession()
        }
        pendingRealtimeLogStopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func cancelPendingRealtimeLogStop() {
        pendingRealtimeLogStopWorkItem?.cancel()
        pendingRealtimeLogStopWorkItem = nil
    }

    private var canUseVoiceInputDuringInvokeHold: Bool {
        switch invokeHoldBehavior {
        case .cursorFollow:
            return searchViewModel.isCommandKeyMode
        case .anchoredInput:
            return true
        case .pinnedFollow:
            return true
        case nil:
            return false
        }
    }

    private var isActivelyStreamingResponse: Bool {
        searchViewModel.claudeManager?.status.isActive ?? false
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
