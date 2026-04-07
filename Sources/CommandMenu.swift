import AppKit
import MarkdownUI
import SwiftUI
import ThisCore

private enum CommandMenuChromeMetrics {
    static let controlWidth: CGFloat = 32
    static let controlHeight: CGFloat = 28
    static let edgePadding: CGFloat = 8
    static let tabSpacing: CGFloat = 1
    static let tabCornerRadius: CGFloat = 8
    static let tabWidth: CGFloat = 160
    static let hoverFadeOutDuration = 0.1
}

private func updateCommandMenuHoverState(_ hovering: Bool, state: Binding<Bool>) {
    if hovering {
        state.wrappedValue = true
    } else {
        withAnimation(.easeOut(duration: CommandMenuChromeMetrics.hoverFadeOutDuration)) {
            state.wrappedValue = false
        }
    }
}

private final class CommandMenuChatScrollController: ObservableObject {
    enum ScrollOutcome {
        case unavailable
        case moved
        case atBoundary
    }

    enum VerticalDirection {
        case up
        case down
    }

    private weak var scrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?
    private let boundaryTolerance: CGFloat = 2
    private let minimumStep: CGFloat = 24
    @Published private(set) var shouldAutoFollowBottom = true

    deinit {
        detach()
    }

    func attach(to scrollView: NSScrollView?) {
        guard self.scrollView !== scrollView else { return }
        detach()
        self.scrollView = scrollView
        shouldAutoFollowBottom = true
        guard let scrollView else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.syncAutoFollowState()
        }
    }

    func detach() {
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
        boundsObserver = nil
        scrollView = nil
        shouldAutoFollowBottom = true
    }

    func enableAutoFollowBottom() {
        shouldAutoFollowBottom = true
    }

    func suspendAutoFollowBottom() {
        shouldAutoFollowBottom = false
    }

    func scrollByKeyboard(_ direction: VerticalDirection) -> ScrollOutcome {
        guard let metrics = currentMetrics() else { return .unavailable }
        switch direction {
        case .up:
            if metrics.isAtTop(tolerance: boundaryTolerance) {
                return .atBoundary
            }
            let step = max(metrics.scrollView.verticalLineScroll * 3, minimumStep)
            setOffsetFromTop(metrics.currentOffsetFromTop - step, using: metrics)
            return .moved
        case .down:
            if metrics.isAtBottom(tolerance: boundaryTolerance) {
                return .atBoundary
            }
            let step = max(metrics.scrollView.verticalLineScroll * 3, minimumStep)
            setOffsetFromTop(metrics.currentOffsetFromTop + step, using: metrics)
            return .moved
        }
    }

    func scrollToTop() -> ScrollOutcome {
        guard let metrics = currentMetrics() else { return .unavailable }
        if metrics.isAtTop(tolerance: boundaryTolerance) {
            return .atBoundary
        }
        setOffsetFromTop(0, using: metrics)
        return .moved
    }

    func scrollToBottom() -> ScrollOutcome {
        guard let metrics = currentMetrics() else { return .unavailable }
        if metrics.isAtBottom(tolerance: boundaryTolerance) {
            return .atBoundary
        }
        setOffsetFromTop(metrics.maxOffsetFromTop, using: metrics)
        return .moved
    }

    func scrollByPage(_ direction: VerticalDirection) -> ScrollOutcome {
        guard let metrics = currentMetrics() else { return .unavailable }
        let step = max(metrics.visibleHeight * 0.85, 72)
        switch direction {
        case .up:
            if metrics.isAtTop(tolerance: boundaryTolerance) {
                return .atBoundary
            }
            setOffsetFromTop(metrics.currentOffsetFromTop - step, using: metrics)
            return .moved
        case .down:
            if metrics.isAtBottom(tolerance: boundaryTolerance) {
                return .atBoundary
            }
            setOffsetFromTop(metrics.currentOffsetFromTop + step, using: metrics)
            return .moved
        }
    }

    private func currentMetrics() -> ScrollMetrics? {
        guard let scrollView,
              let documentView = scrollView.documentView else { return nil }
        let clipView = scrollView.contentView
        let visibleRect = clipView.documentVisibleRect
        let maxOffsetFromTop = max(documentView.bounds.height - visibleRect.height, 0)
        let currentOffsetFromTop: CGFloat
        if documentView.isFlipped {
            currentOffsetFromTop = visibleRect.minY
        } else {
            currentOffsetFromTop = maxOffsetFromTop - visibleRect.minY
        }
        return ScrollMetrics(
            scrollView: scrollView,
            clipView: clipView,
            documentView: documentView,
            currentOffsetFromTop: currentOffsetFromTop,
            maxOffsetFromTop: maxOffsetFromTop
        )
    }

    private func setOffsetFromTop(_ offsetFromTop: CGFloat, using metrics: ScrollMetrics) {
        let clampedOffset = min(max(offsetFromTop, 0), metrics.maxOffsetFromTop)
        let targetY: CGFloat
        if metrics.documentView.isFlipped {
            targetY = clampedOffset
        } else {
            targetY = metrics.maxOffsetFromTop - clampedOffset
        }
        metrics.clipView.scroll(to: NSPoint(x: metrics.clipView.bounds.origin.x, y: targetY))
        metrics.scrollView.reflectScrolledClipView(metrics.clipView)
        shouldAutoFollowBottom = clampedOffset >= metrics.maxOffsetFromTop - boundaryTolerance
    }

    private func syncAutoFollowState() {
        guard let metrics = currentMetrics() else { return }
        shouldAutoFollowBottom = metrics.isAtBottom(tolerance: boundaryTolerance)
    }

    private struct ScrollMetrics {
        let scrollView: NSScrollView
        let clipView: NSClipView
        let documentView: NSView
        let currentOffsetFromTop: CGFloat
        let maxOffsetFromTop: CGFloat
        var visibleHeight: CGFloat { clipView.bounds.height }

        func isAtTop(tolerance: CGFloat) -> Bool {
            currentOffsetFromTop <= tolerance
        }

        func isAtBottom(tolerance: CGFloat) -> Bool {
            currentOffsetFromTop >= maxOffsetFromTop - tolerance
        }
    }
}

private struct CommandMenuScrollViewAccessor: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onResolve(view.enclosingScrollView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.enclosingScrollView)
        }
    }
}

private final class CommandMenuHeaderResizeDragView: NSView {
    enum CursorMode {
        case none
        case hover
        case dragging
    }

    var isEnabled = true {
        didSet {
            if !isEnabled {
                dragStartY = nil
                dragStartHeight = nil
                onDragEnded?()
                setCursorMode(.none)
            }
        }
    }
    var expectedSurfaceWidth: CGFloat = 720
    var onDragChanged: ((CGFloat?, CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onReset: (() -> Void)?

    private var dragStartY: CGFloat?
    private var dragStartHeight: CGFloat?
    private var trackingArea: NSTrackingArea?
    private var cursorMode: CursorMode = .none

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled, dragStartY == nil else { return }
        setCursorMode(.hover)
    }

    override func mouseExited(with event: NSEvent) {
        guard dragStartY == nil else { return }
        setCursorMode(.none)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2 {
            onReset?()
            return
        }

        dragStartY = event.locationInWindow.y
        dragStartHeight = currentSurfaceHeightFromHierarchy()
        setCursorMode(.dragging)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartY else { return }
        if dragStartHeight == nil {
            dragStartHeight = currentSurfaceHeightFromHierarchy()
        }
        onDragChanged?(dragStartHeight, event.locationInWindow.y - dragStartY)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartY != nil else { return }
        dragStartY = nil
        dragStartHeight = nil
        onDragEnded?()

        let localPoint = convert(event.locationInWindow, from: nil)
        setCursorMode(bounds.contains(localPoint) ? .hover : .none)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            dragStartY = nil
            dragStartHeight = nil
            onDragEnded?()
            setCursorMode(.none)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func currentSurfaceHeightFromHierarchy() -> CGFloat? {
        var candidate = superview
        var bestMatch: CGFloat = 0

        while let view = candidate {
            let size = view.bounds.size
            if abs(size.width - expectedSurfaceWidth) <= 2, size.height > bestMatch {
                bestMatch = size.height
            }
            candidate = view.superview
        }

        return bestMatch > 0 ? bestMatch : nil
    }

    private func setCursorMode(_ newMode: CursorMode) {
        guard cursorMode != newMode else { return }
        if cursorMode != .none {
            NSCursor.pop()
        }
        cursorMode = newMode
        switch newMode {
        case .none:
            break
        case .hover:
            NSCursor.openHand.push()
        case .dragging:
            NSCursor.closedHand.push()
        }
    }
}

private struct CommandMenuHeaderResizeArea: NSViewRepresentable {
    let isEnabled: Bool
    let surfaceWidth: CGFloat
    let onDragChanged: (CGFloat?, CGFloat) -> Void
    let onDragEnded: () -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> CommandMenuHeaderResizeDragView {
        let view = CommandMenuHeaderResizeDragView(frame: .zero)
        view.expectedSurfaceWidth = surfaceWidth
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.onReset = onReset
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ nsView: CommandMenuHeaderResizeDragView, context: Context) {
        nsView.expectedSurfaceWidth = surfaceWidth
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
        nsView.onReset = onReset
        nsView.isEnabled = isEnabled
    }
}

private final class CommandMenuResizeHandleView: NSView {
    weak var panel: CommandMenuPanel?

    private var dragStartY: CGFloat?
    private var trackingArea: NSTrackingArea?
    private var isCursorActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isCursorActive else { return }
        NSCursor.resizeUpDown.push()
        isCursorActive = true
    }

    override func mouseExited(with event: NSEvent) {
        deactivateCursor()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            deactivateCursor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            panel?.resetResizeHeight()
            return
        }

        dragStartY = event.locationInWindow.y
        panel?.beginResizeDrag()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartY else { return }
        panel?.updateResizeDrag(deltaY: event.locationInWindow.y - dragStartY)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartY = nil
        panel?.endResizeDrag()
    }

    private func deactivateCursor() {
        guard isCursorActive else { return }
        NSCursor.pop()
        isCursorActive = false
    }
}

final class CommandMenuPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onClickOutsideContent: (() -> Void)?
    var onShortcut: ((NSEvent) -> Bool)?
    var isPinned = false
    var isResizeEnabled = false {
        didSet { passthrough?.isResizeEnabled = isResizeEnabled }
    }
    var onResizeDelta: ((CGFloat, CGFloat) -> Void)?
    var onResetHeight: (() -> Void)?

    private var hostingView: NSHostingView<AnyView>?
    private var passthrough: CommandMenuPassthroughView?
    private var resizeStartHeight: CGFloat?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setRootView<Content: View>(_ rootView: Content) {
        if let hostingView {
            hostingView.rootView = AnyView(rootView)
        } else {
            let hostingView = NSHostingView(rootView: AnyView(rootView))
            hostingView.autoresizingMask = [.width, .height]
            self.hostingView = hostingView
        }

        installSurfaceIfNeeded()
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onShortcut?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func fillScreen(_ screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }

    /// Called by SwiftUI when the visible content frame changes (in window coordinates).
    func updateContentFrame(_ rect: CGRect) {
        passthrough?.contentFrame = rect
    }

    func beginResizeDrag() {
        resizeStartHeight = passthrough?.contentFrame.height
    }

    func updateResizeDrag(deltaY: CGFloat) {
        let startHeight = resizeStartHeight ?? passthrough?.contentFrame.height ?? 0
        guard startHeight > 0 else { return }
        onResizeDelta?(startHeight, deltaY)
    }

    func endResizeDrag() {
        resizeStartHeight = nil
    }

    func resetResizeHeight() {
        resizeStartHeight = nil
        onResetHeight?()
    }

    private func installSurfaceIfNeeded() {
        guard let hostingView else { return }

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        if passthrough == nil {
            let container = CommandMenuPassthroughView(frame: .zero)
            container.panel = self
            container.autoresizingMask = [.width, .height]
            passthrough = container
        }

        if hostingView.superview !== passthrough {
            passthrough?.addSubview(hostingView)
            hostingView.frame = passthrough?.bounds ?? .zero
        }

        passthrough?.positionResizeHandle(above: hostingView)
        passthrough?.isResizeEnabled = isResizeEnabled

        contentView = passthrough
    }
}

/// Custom NSView that passes mouse clicks through to apps behind when
/// they land outside the visible command-menu content area.
private final class CommandMenuPassthroughView: NSView {
    weak var panel: CommandMenuPanel?
    var contentFrame: CGRect = .zero {
        didSet { updateResizeHandleFrame() }
    }
    var isResizeEnabled = false {
        didSet { resizeHandleView.isHidden = !isResizeEnabled }
    }

    private let resizeHandleView = CommandMenuResizeHandleView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        resizeHandleView.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateResizeHandleFrame()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // If the click is inside the content frame, do normal hit-testing
        if contentFrame.contains(point) {
            return super.hitTest(point)
        }
        // Don't dismiss if the content frame hasn't been reported yet — the
        // GeometryReader fires asynchronously, so the very first hit test
        // after the panel appears would otherwise see .zero and dismiss
        // immediately.
        guard contentFrame != .zero else {
            return super.hitTest(point)
        }
        // Otherwise, dismiss if unpinned and pass through
        if let panel, !panel.isPinned {
            panel.onClickOutsideContent?()
        }
        return nil
    }

    // Make the transparent areas invisible to accessibility queries so that
    // floating panels can detect what's behind the command menu window.
    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        // Only return accessibility elements for the visible content area.
        // Convert screen point to local coordinates.
        guard let window else { return nil }
        let windowPoint = window.convertPoint(fromScreen: point)
        let localPoint = convert(windowPoint, from: nil)
        if contentFrame != .zero && !contentFrame.contains(localPoint) {
            return nil
        }
        return super.accessibilityHitTest(point)
    }

    func positionResizeHandle(above hostingView: NSView) {
        resizeHandleView.panel = panel
        guard resizeHandleView.superview == nil else { return }
        addSubview(resizeHandleView, positioned: .above, relativeTo: hostingView)
        updateResizeHandleFrame()
    }

    private func updateResizeHandleFrame() {
        resizeHandleView.frame = CGRect(
            x: contentFrame.minX,
            y: max(contentFrame.maxY - CommandMenuView.resizeHandleHeightValue, contentFrame.minY),
            width: contentFrame.width,
            height: min(CommandMenuView.resizeHandleHeightValue, contentFrame.height)
        )
    }
}

struct CommandMenuView: View {
    private static let panelWidth: CGFloat = 720
    private static let maxChatHeight: CGFloat = 500
    private static let fallbackBottomBarHeight: CGFloat = 48
    private static let fallbackNonChatChromeHeight: CGFloat = 160
    private static let bottomMargin: CGFloat = 80
    private static let minimumVisibleChatHeight: CGFloat = 120
    static let resizeHandleHeightValue: CGFloat = 12

    @ObservedObject var appDelegate: AppDelegate
    let presentationID: UUID
    @State private var isContentVisible = false
    @State private var textWidth: CGFloat = FocusedTextField.minWidth
    @State private var textHeight: CGFloat = 20
    @State private var contentFrame: CGRect = .zero
    @State private var renderedSurfaceHeight: CGFloat = 0
    @State private var renderedChatViewportHeight: CGFloat = 0
    @State private var isHeaderHovering = false
    @State private var fastModeEnabled = AppSettings.fastModeEnabled
    @State private var thinkingEnabled = AppSettings.thinkingEnabled
    @State private var planModeEnabled = AppSettings.planModeEnabled
    @State private var selectedModel = AppSettings.defaultModel
    @State private var headerResizeStartHeight: CGFloat?
    @State private var headerResizeLockedChromeHeight: CGFloat?
    @StateObject private var chatScrollController = CommandMenuChatScrollController()

    private var usesNativeGlassSurface: Bool {
        false
    }

    private var tabs: [TaskSessionRecord] {
        appDelegate.taskRecords
    }

    private var query: String {
        get { appDelegate.commandMenuQuery }
        nonmutating set { appDelegate.commandMenuQuery = newValue }
    }

    private var trimmedQuery: String {
        appDelegate.commandMenuQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var queryIsEmpty: Bool {
        trimmedQuery.isEmpty
    }

    private var isExpanded: Bool {
        activeChatRecord != nil || isDraftSelected
    }

    private var activeChatRecord: TaskSessionRecord? {
        appDelegate.commandMenuChatRecord
    }

    private var hasLiveChat: Bool {
        activeChatRecord != nil
    }

    private var isDraftSelected: Bool {
        appDelegate.commandMenuShowingDraft
    }

    private var hasTasks: Bool {
        !tabs.isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            let screenHeight = geometry.size.height

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                VStack(spacing: 0) {
                    titleBar(screenHeight: screenHeight)

                    Divider()

                    headerRow

                    Divider()

                    if isExpanded {
                        chatSection(screenHeight: screenHeight)

                        Divider()
                    }

                    inputRow
                }
                .frame(width: Self.panelWidth, height: resolvedManualTotalHeight(screenHeight: screenHeight))
                .modifier(CommandMenuSurfaceChrome(usesNativeGlassSurface: usesNativeGlassSurface))
                .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 5)
                .opacity(isContentVisible ? 1 : 0)
                .blur(radius: isContentVisible ? 0 : 10)
                .offset(y: isContentVisible ? 0 : 8)
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .preference(
                                key: CommandMenuContentFramePreferenceKey.self,
                                value: geometry.frame(in: .global)
                            )
                            .preference(
                                key: CommandMenuSurfaceHeightPreferenceKey.self,
                                value: geometry.size.height
                            )
                    }
                )
                .padding(.bottom, Self.bottomMargin)
                .animation(.easeInOut(duration: 0.25), value: isExpanded)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .id(presentationID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(CommandMenuContentFramePreferenceKey.self) { frame in
            guard frame.width > 0, frame.height > 0 else { return }
            contentFrame = frame
            appDelegate.updateCommandMenuContentFrame(frame)
        }
        .onPreferenceChange(CommandMenuSurfaceHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            renderedSurfaceHeight = height
        }
        .onPreferenceChange(CommandMenuChatViewportHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            renderedChatViewportHeight = height
            appDelegate.updateCommandMenuChatViewportHeight(height)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) {
                isContentVisible = true
            }
        }
        .onChange(of: hasLiveChat) { _, hasLiveChat in
            if !hasLiveChat {
                contentFrame = .zero
                renderedSurfaceHeight = 0
                renderedChatViewportHeight = 0
                appDelegate.updateCommandMenuChatViewportHeight(0)
            }
        }
        .onChange(of: appDelegate.commandMenuDismissing) { _, dismissing in
            guard dismissing else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                isContentVisible = false
            }
            clearHeaderResizeSession()
        }
        .onChange(of: canResizeFromHeader) { _, canResize in
            if !canResize {
                clearHeaderResizeSession()
            }
        }
    }

    private func titleBar(screenHeight: CGFloat) -> some View {
        HStack(spacing: 0) {
            SettingsMenuButton()
                .padding(.leading, CommandMenuChromeMetrics.edgePadding)

            HStack(spacing: 2) {
                ModelPickerButton(selectedModel: $selectedModel)
                HeaderToggleButton(
                    icon: "hare",
                    label: "Fast",
                    isOn: fastModeEnabled,
                    isVisible: selectedModel.isOpus
                ) {
                    fastModeEnabled.toggle()
                    AppSettings.fastModeEnabled = fastModeEnabled
                }
                HeaderToggleButton(
                    icon: "brain",
                    label: "Thinking",
                    isOn: thinkingEnabled
                ) {
                    thinkingEnabled.toggle()
                    AppSettings.thinkingEnabled = thinkingEnabled
                }
                HeaderToggleButton(
                    icon: "map",
                    label: "Plan",
                    isOn: planModeEnabled
                ) {
                    planModeEnabled.toggle()
                    AppSettings.planModeEnabled = planModeEnabled
                }
            }
            .padding(.leading, 4)
            .opacity(isHeaderHovering ? 1 : 0)

            if canResizeFromHeader {
                headerResizeArea(screenHeight: screenHeight)
            } else {
                Spacer(minLength: 0)
            }

            HStack(spacing: 1) {
                CommandMenuPinButton(isPinned: $appDelegate.commandMenuPinned)
                    .opacity(isHeaderHovering ? 1 : 0)

                if shouldShowHeightResetControl {
                    CommandMenuResetHeightButton(onReset: resetPinnedHeightMode)
                }

                CommandMenuMinimizeCloseButton(
                    isExpanded: isExpanded,
                    onMinimize: {
                        appDelegate.minimizeCommandMenu()
                    },
                    onClose: { appDelegate.closeCommandMenu() }
                )
            }
            .padding(.trailing, CommandMenuChromeMetrics.edgePadding)
        }
        .frame(height: Self.fallbackBottomBarHeight)
        .background(Color.black.opacity(0.035))
        .onHover { hovering in
            withAnimation(.easeOut(duration: CommandMenuChromeMetrics.hoverFadeOutDuration)) {
                isHeaderHovering = hovering
            }
        }
    }

    private func headerResizeArea(screenHeight: CGFloat) -> some View {
        CommandMenuHeaderResizeArea(
            isEnabled: canResizeFromHeader,
            surfaceWidth: Self.panelWidth,
            onDragChanged: { startHeight, deltaY in
                updatePinnedHeightFromHeaderDrag(
                    startHeight: startHeight,
                    deltaY: deltaY,
                    screenHeight: screenHeight
                )
            },
            onDragEnded: {
                clearHeaderResizeSession()
            },
            onReset: {
                resetPinnedHeightMode()
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerRow: some View {
        HStack(spacing: CommandMenuChromeMetrics.tabSpacing) {
            CommandMenuNewTabButton(
                isSelected: isDraftSelected,
                action: { openNewTab() }
            )
            .padding(.leading, CommandMenuChromeMetrics.edgePadding)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CommandMenuChromeMetrics.tabSpacing) {
                        ForEach(tabs) { task in
                            CommandMenuTabButton(
                                task: task,
                                isSelected: activeChatRecord?.id == task.id,
                                onTap: { toggleTab(task) },
                                onClose: { closeTab(task) }
                            )
                            .id(task.id)
                        }
                    }
                    .padding(.trailing, CommandMenuChromeMetrics.edgePadding)
                    .padding(.vertical, 8)
                }
                .onAppear {
                    DispatchQueue.main.async {
                        scrollTabStripToInitialPosition(proxy)
                    }
                }
                .onChange(of: activeChatRecord?.id) { _, newID in
                    guard let newID else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
            }
        }
    }

    private func scrollTabStripToInitialPosition(_ proxy: ScrollViewProxy) {
        if let activeID = activeChatRecord?.id {
            proxy.scrollTo(activeID, anchor: .center)
        } else if let latestID = tabs.first?.id {
            proxy.scrollTo(latestID, anchor: .leading)
        }
    }

    @ViewBuilder
    private func chatSection(screenHeight: CGFloat) -> some View {
        if let chatRecord = activeChatRecord,
           let viewModel = chatRecord.panel?.searchViewModel {
            CommandMenuChatSection(
                viewModel: viewModel,
                scrollController: chatScrollController,
                manualViewportHeight: manualChatViewportHeight(screenHeight: screenHeight)
            )
            .id(chatRecord.id)
            .clipped()
        } else if isDraftSelected {
            CommandMenuDraftSection()
        }
    }

    private var inputRow: some View {
        CommandMenuTextInputRow(
            text: $appDelegate.commandMenuQuery,
            textWidth: $textWidth,
            textHeight: $textHeight,
            placeholder: activeChatRecord != nil ? "Message this task..." : "Ask Claude Code anything…",
            voiceState: appDelegate.commandMenuVoiceState,
            isStreaming: activeChatRecord?.isRunning == true,
            onSubmit: submitInput,
            onStop: stopActiveTask,
            onVoice: { self.appDelegate.toggleCommandMenuVoice() },
            onKeyDown: handleInputKeyDown,
            onCommandSelector: handleInputCommandSelector
        )
    }


    private func switchToPreviousTab() {
        guard !tabs.isEmpty else { return }
        guard let currentID = activeChatRecord?.id ?? appDelegate.commandMenuTabNavigationAnchorID(),
              let currentIndex = tabs.firstIndex(where: { $0.id == currentID }) else {
            if let first = tabs.first {
                appDelegate.openTaskRecord(first)
            }
            return
        }
        let previousIndex = currentIndex > 0 ? currentIndex - 1 : tabs.count - 1
        appDelegate.openTaskRecord(tabs[previousIndex])
    }

    private func switchToNextTab() {
        guard !tabs.isEmpty else { return }
        guard let currentID = activeChatRecord?.id ?? appDelegate.commandMenuTabNavigationAnchorID(),
              let currentIndex = tabs.firstIndex(where: { $0.id == currentID }) else {
            if let first = tabs.first {
                appDelegate.openTaskRecord(first)
            }
            return
        }
        let nextIndex = currentIndex < tabs.count - 1 ? currentIndex + 1 : 0
        appDelegate.openTaskRecord(tabs[nextIndex])
    }

    private func toggleTab(_ task: TaskSessionRecord) {
        if activeChatRecord?.id == task.id {
            appDelegate.handleCommandMenuBackNavigation()
        } else {
            appDelegate.openTaskRecord(task)
        }
    }

    private func closeTab(_ task: TaskSessionRecord) {
        appDelegate.closeTaskRecord(task)
    }

    private func openNewTab() {
        appDelegate.openCommandMenuDraftTab()
    }

    private func selectTabByNumber(_ number: Int) {
        guard !tabs.isEmpty else { return }
        let index: Int
        if number == 9 {
            // Cmd+9 always selects the last tab
            index = tabs.count - 1
        } else {
            index = number - 1
        }
        guard index < tabs.count else { return }
        appDelegate.openTaskRecord(tabs[index])
    }

    private func stopActiveTask() {
        if let record = activeChatRecord, record.isRunning {
            appDelegate.stopTaskRecord(record)
        }
    }

    private func submitInput() {
        guard !queryIsEmpty else { return }
        if isExpanded, let chatVM = activeChatRecord?.panel?.searchViewModel {
            // Copy the input text to the chat's view model and submit
            chatVM.query = trimmedQuery
            query = ""
            chatVM.submitMessage()
        } else {
            if appDelegate.launchTaskFromCommandMenu(query: trimmedQuery) != nil {
                query = ""
            }
        }
    }

    private func handleUpNavigation(command: Bool) -> Bool {
        guard queryIsEmpty else { return false }

        if activeChatRecord != nil, !isDraftSelected {
            chatScrollController.suspendAutoFollowBottom()
            let outcome = command ? chatScrollController.scrollToTop() : chatScrollController.scrollByKeyboard(.up)
            return outcome != .unavailable
        }

        if !command, !isExpanded {
            appDelegate.reopenRememberedOrLatestTaskRecord()
            return true
        }

        return false
    }

    private func handleDownNavigation(command: Bool) -> Bool {
        guard queryIsEmpty,
              activeChatRecord != nil,
              !isDraftSelected else { return false }

        chatScrollController.suspendAutoFollowBottom()
        let outcome = command ? chatScrollController.scrollToBottom() : chatScrollController.scrollByKeyboard(.down)
        switch outcome {
        case .atBoundary:
            appDelegate.minimizeCommandMenu()
            return true
        case .moved:
            return true
        case .unavailable:
            return false
        }
    }

    private func handlePageUpNavigation() -> Bool {
        guard queryIsEmpty,
              activeChatRecord != nil,
              !isDraftSelected else { return true }

        chatScrollController.suspendAutoFollowBottom()
        let outcome = chatScrollController.scrollByPage(.up)
        return outcome != .unavailable
    }

    private func handlePageDownNavigation() -> Bool {
        guard queryIsEmpty,
              activeChatRecord != nil,
              !isDraftSelected else { return true }

        chatScrollController.suspendAutoFollowBottom()
        let outcome = chatScrollController.scrollByPage(.down)
        switch outcome {
        case .atBoundary:
            appDelegate.minimizeCommandMenu()
            return true
        case .moved:
            return true
        case .unavailable:
            return false
        }
    }

    private func handleInputKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = modifiers.contains(.command)
        let hasShift = modifiers.contains(.shift)

        switch event.keyCode {
        case 36, 76: // Return, Enter
            if hasCommand && hasShift && !queryIsEmpty && !isExpanded {
                sendQueryAsFeedback()
                return true
            }

            submitInput()
            return true
        case 51: // Delete
            if hasCommand && hasShift {
                let hasRunningTasks = tabs.contains(where: \.isRunning)
                guard hasRunningTasks else { return false }
                killAllRunningTasks()
                return true
            }

            if modifiers.isEmpty, queryIsEmpty, isExpanded {
                if let record = activeChatRecord, record.isRunning {
                    appDelegate.stopTaskRecord(record)
                    return true
                }
            }
        case 12: // Q
            if hasCommand {
                appDelegate.quitFromCommandMenu()
                return true
            }
        case 37: // L
            if hasCommand {
                openFeedback()
                return true
            }
        case 32: // U
            if hasCommand {
                appDelegate.checkForUpdatesFromCommandMenu()
                return true
            }
        case 3: // F
            if hasCommand && hasShift {
                openFeedback()
                return true
            }
        case 43: // comma
            if hasCommand {
                openSettings()
                return true
            }
        case 46: // M
            if hasCommand {
                appDelegate.minimizeCommandMenu()
                return true
            }
        case 17: // T
            if hasCommand && hasShift {
                appDelegate.reopenLastClosedTaskRecord()
                return true
            }
            if hasCommand {
                openNewTab()
                return true
            }
        case 48: // Tab
            if modifiers.isEmpty {
                return handlePageDownNavigation()
            }
            if modifiers == [.shift] {
                return handlePageUpNavigation()
            }
        case 33: // [
            if hasCommand && hasShift {
                switchToPreviousTab()
                return true
            }
        case 13: // W
            if hasCommand {
                if let activeChatRecord {
                    appDelegate.closeTaskRecord(activeChatRecord)
                    return true
                }
                if isDraftSelected {
                    appDelegate.minimizeCommandMenu()
                    return true
                }
            }
        case 126: // Up arrow
            if modifiers.isEmpty {
                return handleUpNavigation(command: false)
            }
            if modifiers == [.command] {
                return handleUpNavigation(command: true)
            }
        case 125: // Down arrow
            if modifiers.isEmpty {
                return handleDownNavigation(command: false)
            }
            if modifiers == [.command] {
                return handleDownNavigation(command: true)
            }
        case 123: // Left arrow
            if modifiers.isEmpty, queryIsEmpty {
                switchToPreviousTab()
                return true
            }
        case 30: // ]
            if hasCommand && hasShift {
                switchToNextTab()
                return true
            }
        case 124: // Right arrow
            if modifiers.isEmpty, queryIsEmpty {
                switchToNextTab()
                return true
            }
        case 18, 19, 20, 21, 23, 22, 26, 28, 25: // 1-9
            if hasCommand && !hasShift {
                let digitMap: [UInt16: Int] = [
                    18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
                    22: 6, 26: 7, 28: 8, 25: 9
                ]
                if let digit = digitMap[event.keyCode] {
                    selectTabByNumber(digit)
                    return true
                }
            }
        default:
            break
        }

        return false
    }

    private func handleInputCommandSelector(_ selector: Selector) -> Bool {
        guard queryIsEmpty else { return false }

        if selector == #selector(NSResponder.moveUp(_:)) {
            return handleUpNavigation(command: false)
        }

        if selector == #selector(NSResponder.moveToBeginningOfDocument(_:)) {
            return handleUpNavigation(command: true)
        }

        if selector == #selector(NSResponder.moveDown(_:)) {
            return handleDownNavigation(command: false)
        }

        if selector == #selector(NSResponder.moveToEndOfDocument(_:)) {
            return handleDownNavigation(command: true)
        }

        if selector == #selector(NSResponder.insertTab(_:)) {
            return handlePageDownNavigation()
        }

        if selector == #selector(NSResponder.insertBacktab(_:)) {
            return handlePageUpNavigation()
        }

        if selector == #selector(NSResponder.moveLeft(_:)) {
            switchToPreviousTab()
            return true
        }

        if selector == #selector(NSResponder.moveRight(_:)) {
            switchToNextTab()
            return true
        }

        return false
    }

    private func openSettings() {
        appDelegate.openSettingsFromCommandMenu()
    }

    private func openFeedback() {
        appDelegate.openFeedbackFromCommandMenu()
    }

    private func sendQueryAsFeedback() {
        guard !queryIsEmpty else { return }
        let feedbackDraft = trimmedQuery
        query = ""
        appDelegate.openFeedbackFromCommandMenu(draft: feedbackDraft)
    }

    private func killAllRunningTasks() {
        appDelegate.stopAllRunningTaskRecords()
    }

    private var shouldShowHeightResetControl: Bool {
        shouldShowCommandMenuHeightResetControl(
            isPinned: appDelegate.commandMenuPinned,
            hasLiveChat: hasLiveChat,
            heightMode: appDelegate.commandMenuPinnedHeightMode,
            isCommandMenuDismissing: appDelegate.commandMenuDismissing
        )
    }

    private var canResizeFromHeader: Bool {
        canResizePinnedCommandMenuHeight(
            isPinned: appDelegate.commandMenuPinned,
            hasLiveChat: hasLiveChat,
            isCommandMenuDismissing: appDelegate.commandMenuDismissing
        )
    }

    private var effectiveManualChromeHeight: CGFloat {
        headerResizeLockedChromeHeight ?? measuredNonChatChromeHeight
    }

    private var measuredNonChatChromeHeight: CGFloat {
        guard hasLiveChat,
              contentFrame.height > 0,
              renderedChatViewportHeight > 0 else {
            return Self.fallbackNonChatChromeHeight
        }

        return max(contentFrame.height - renderedChatViewportHeight, Self.fallbackNonChatChromeHeight)
    }

    private func manualHeightBounds(screenHeight: CGFloat) -> CommandMenuManualHeightBounds {
        commandMenuManualHeightBounds(
            screenHeight: screenHeight,
            bottomMargin: Self.bottomMargin,
            chromeHeight: effectiveManualChromeHeight,
            minimumVisibleChatHeight: Self.minimumVisibleChatHeight
        )
    }

    private func resolvedManualTotalHeight(screenHeight: CGFloat) -> CGFloat? {
        guard appDelegate.commandMenuPinned, hasLiveChat else { return nil }
        guard case let .manual(totalHeight) = appDelegate.commandMenuPinnedHeightMode else { return nil }

        return clampedCommandMenuManualHeight(
            totalHeight,
            bounds: manualHeightBounds(screenHeight: screenHeight)
        )
    }

    private func manualChatViewportHeight(screenHeight: CGFloat) -> CGFloat? {
        guard let totalHeight = resolvedManualTotalHeight(screenHeight: screenHeight) else { return nil }
        return max(totalHeight - effectiveManualChromeHeight, Self.minimumVisibleChatHeight)
    }

    private func currentSurfaceHeight(screenHeight: CGFloat) -> CGFloat? {
        if let manualHeight = resolvedManualTotalHeight(screenHeight: screenHeight) {
            return manualHeight
        }

        return commandMenuStartingSurfaceHeight(
            reportedTotalHeight: max(renderedSurfaceHeight, contentFrame.height),
            chromeHeight: effectiveManualChromeHeight,
            chatViewportHeight: renderedChatViewportHeight
        )
    }

    private func updatePinnedHeightFromHeaderDrag(
        startHeight: CGFloat?,
        deltaY: CGFloat,
        screenHeight: CGFloat
    ) {
        if headerResizeStartHeight == nil {
            headerResizeLockedChromeHeight = measuredNonChatChromeHeight
            headerResizeStartHeight = startHeight ?? currentSurfaceHeight(screenHeight: screenHeight)
        }

        guard let headerResizeStartHeight else { return }

        let nextHeight = commandMenuManualHeightAfterDrag(
            startHeight: headerResizeStartHeight,
            dragDeltaY: deltaY,
            bounds: manualHeightBounds(screenHeight: screenHeight)
        )
        appDelegate.commandMenuPinnedHeightMode = .manual(totalHeight: nextHeight)
    }

    private func clearHeaderResizeSession() {
        headerResizeStartHeight = nil
        headerResizeLockedChromeHeight = nil
    }

    private func resetPinnedHeightMode() {
        clearHeaderResizeSession()
        appDelegate.commandMenuPinnedHeightMode = .automatic
    }

}

private struct CommandMenuSurfaceChrome: ViewModifier {
    let usesNativeGlassSurface: Bool

    func body(content: Content) -> some View {
        if usesNativeGlassSurface {
            content
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else {
            content
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
        }
    }
}


private struct CommandMenuChatSection: View {
    @ObservedObject var viewModel: SearchViewModel
    @ObservedObject var scrollController: CommandMenuChatScrollController
    let manualViewportHeight: CGFloat?
    @State private var scrollContentHeight: CGFloat = 0
    private let maxScrollAreaHeight: CGFloat = 500

    private var resolvedViewportHeight: CGFloat {
        if let manualViewportHeight {
            return manualViewportHeight
        }

        return min(max(scrollContentHeight + 16, 60), maxScrollAreaHeight)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    chatTranscript
                    Spacer(minLength: 0)
                }
                .background(
                    ZStack {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: CommandMenuChatContentHeightPreferenceKey.self,
                                value: geometry.size.height
                            )
                        }
                        CommandMenuScrollViewAccessor { scrollView in
                            scrollController.attach(to: scrollView)
                        }
                    }
                )
            }
            .frame(height: resolvedViewportHeight)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: CommandMenuChatViewportHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            )
            .onAppear {
                forceScrollToBottom(proxy, animated: false)
            }
            .onChange(of: viewModel.claudeManager?.outputText) { _, _ in
                scrollToBottomIfNeeded(proxy)
            }
            .onChange(of: viewModel.chatHistory.count) { _, _ in
                if viewModel.claudeManager?.status == .done {
                    forceScrollToBottom(proxy)
                } else {
                    scrollToBottomIfNeeded(proxy)
                }
            }
            .onChange(of: viewModel.claudeManager?.events.count) { _, _ in
                scrollToBottomIfNeeded(proxy)
            }
            .onPreferenceChange(CommandMenuChatContentHeightPreferenceKey.self) { height in
                scrollContentHeight = height
            }
            .onDisappear {
                scrollController.detach()
            }
        }
    }

    private func scrollToBottomIfNeeded(_ proxy: ScrollViewProxy) {
        guard scrollController.shouldAutoFollowBottom else { return }
        forceScrollToBottom(proxy)
    }

    private func forceScrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        scrollController.enableAutoFollowBottom()
        if animated {
            withAnimation(.easeOut(duration: 0.1)) {
                proxy.scrollTo("chatBottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("chatBottom", anchor: .bottom)
        }
    }

    private var chatTranscript: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(viewModel.chatHistory) { entry in
                if entry.role == "user" {
                    HStack {
                        Spacer(minLength: 40)
                        Text(entry.text)
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                } else {
                    EventsSummaryView(events: entry.events, isDone: true)
                    AssistantContentView(text: entry.text, structuredUI: entry.structuredUI)
                }
            }

            if let manager = viewModel.claudeManager {
                StreamingContentView(manager: manager)
            }

            Spacer().frame(height: 0).id("chatBottom")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct CommandMenuDraftSection: View {
    private static let minHeight: CGFloat = 132

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.minHeight)
    }
}

private struct CommandMenuNewTabButton: View {
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle((isSelected || isHovering) ? .primary : .secondary)
                .frame(
                    width: CommandMenuChromeMetrics.controlWidth,
                    height: CommandMenuChromeMetrics.controlHeight
                )
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: CommandMenuChromeMetrics.tabCornerRadius,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(CommandMenuChromeButtonStyle(isHovering: isHovering, isActive: isSelected))
        .onHover { hovering in
            updateCommandMenuHoverState(hovering, state: $isHovering)
        }
        .help("New tab")
    }
}

private struct CommandMenuTabButton: View {
    @ObservedObject var task: TaskSessionRecord
    let isSelected: Bool
    let onTap: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @State private var isCloseHovering = false

    private var backgroundOpacity: Double {
        if isSelected { return 0.12 }
        if isHovering { return 0.06 }
        return 0
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onTap) {
                HStack(spacing: 6) {
                    if let icon = task.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    Text(task.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)

                    if task.isRunning {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                    } else if task.isUnread {
                        Circle()
                            .fill(Color.secondary)
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(isCloseHovering ? 0.12 : 0.06))

                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                }
                .frame(width: 20, height: 20)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .onHover { hovering in
                updateCommandMenuHoverState(hovering, state: $isCloseHovering)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: CommandMenuChromeMetrics.tabWidth)
        .background(
            RoundedRectangle(cornerRadius: CommandMenuChromeMetrics.tabCornerRadius, style: .continuous)
                .fill(Color.black.opacity(backgroundOpacity))
        )
        .contentShape(RoundedRectangle(cornerRadius: CommandMenuChromeMetrics.tabCornerRadius, style: .continuous))
        .onHover { hovering in
            updateCommandMenuHoverState(hovering, state: $isHovering)
        }
    }
}

private struct CommandMenuChatContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CommandMenuChatViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CommandMenuTextInputRow: View {
    @Binding var text: String
    @Binding var textWidth: CGFloat
    @Binding var textHeight: CGFloat
    let placeholder: String
    let voiceState: SearchViewModel.VoiceState
    let isStreaming: Bool
    let onSubmit: () -> Void
    let onStop: () -> Void
    let onVoice: () -> Void
    var onKeyDown: ((NSEvent) -> Bool)? = nil
    var onCommandSelector: ((Selector) -> Bool)? = nil

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ZStack(alignment: .leading) {
                Text(placeholder)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .opacity(text.isEmpty ? 1 : 0)
                    .allowsHitTesting(false)

                FocusedTextField(
                    text: $text,
                    textWidth: $textWidth,
                    textHeight: $textHeight,
                    onSubmit: onSubmit,
                    onKeyDown: onKeyDown,
                    onCommandSelector: onCommandSelector,
                    font: .systemFont(ofSize: 14, weight: .regular)
                )
                .frame(height: max(textHeight, 22))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            CommandMenuInputActionButton(
                hasText: hasText,
                isStreaming: isStreaming,
                voiceState: voiceState,
                onSubmit: onSubmit,
                onStop: onStop,
                onVoice: onVoice
            )
        }
        .padding(.leading, 18)
        .padding(.trailing, CommandMenuChromeMetrics.edgePadding)
        .padding(.vertical, 16)
    }
}

private struct CommandMenuInputActionButton: View {
    let hasText: Bool
    let isStreaming: Bool
    let voiceState: SearchViewModel.VoiceState
    let onSubmit: () -> Void
    let onStop: () -> Void
    let onVoice: () -> Void

    private var isVoiceActive: Bool {
        switch voiceState {
        case .listening, .transcribing:
            return true
        case .idle, .failed:
            return false
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if isStreaming {
                SingleActionButton(
                    icon: "stop.fill",
                    action: onStop,
                    accessibilityLabel: "Stop"
                )
            } else {
                // Mic / stop-voice button — always visible
                SingleActionButton(
                    icon: isVoiceActive ? "stop.fill" : "mic",
                    action: onVoice,
                    accessibilityLabel: isVoiceActive ? "Stop voice input" : "Voice input"
                )

                // Send button — visible when there is text
                if hasText {
                    SingleActionButton(
                        icon: "arrow.up",
                        action: onSubmit,
                        accessibilityLabel: "Send"
                    )
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isStreaming)
        .animation(.easeInOut(duration: 0.15), value: hasText)
        .animation(.easeInOut(duration: 0.15), value: isVoiceActive)
    }
}

private struct SingleActionButton: View {
    let icon: String
    let action: () -> Void
    let accessibilityLabel: String

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .frame(
                    width: CommandMenuChromeMetrics.controlWidth,
                    height: CommandMenuChromeMetrics.controlHeight
                )
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: CommandMenuChromeMetrics.tabCornerRadius,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(CommandMenuChromeButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            updateCommandMenuHoverState(hovering, state: $isHovering)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}


private final class MenuActionHandler: NSObject {
    var actions: [Int: () -> Void] = [:]

    @objc func performAction(_ sender: NSMenuItem) {
        actions[sender.tag]?()
    }
}

private struct MenuAnchorRepresentable: NSViewRepresentable {
    @Binding var anchorView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { anchorView = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct ClaudeIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Claude asterisk icon scaled to fit rect
        let s = min(rect.width, rect.height) / 16
        let ox = rect.midX - 8 * s
        let oy = rect.midY - 8 * s

        var path = Path()
        // Simplified Claude asterisk – using the SVG path scaled
        path.move(to: CGPoint(x: ox + 3.127 * s, y: oy + 10.604 * s))
        path.addLine(to: CGPoint(x: ox + 6.262 * s, y: oy + 8.844 * s))
        path.addLine(to: CGPoint(x: ox + 6.315 * s, y: oy + 8.691 * s))
        path.addLine(to: CGPoint(x: ox + 6.262 * s, y: oy + 8.606 * s))
        path.addLine(to: CGPoint(x: ox + 6.11 * s, y: oy + 8.606 * s))
        path.addLine(to: CGPoint(x: ox + 5.585 * s, y: oy + 8.574 * s))
        path.addLine(to: CGPoint(x: ox + 3.794 * s, y: oy + 8.526 * s))
        path.addLine(to: CGPoint(x: ox + 2.24 * s, y: oy + 8.461 * s))
        path.addLine(to: CGPoint(x: ox + 0.735 * s, y: oy + 8.381 * s))
        path.addLine(to: CGPoint(x: ox + 0.355 * s, y: oy + 8.3 * s))
        path.addLine(to: CGPoint(x: ox + 0 * s, y: oy + 7.832 * s))
        path.addLine(to: CGPoint(x: ox + 0.036 * s, y: oy + 7.598 * s))
        path.addLine(to: CGPoint(x: ox + 0.356 * s, y: oy + 7.384 * s))
        path.addLine(to: CGPoint(x: ox + 0.811 * s, y: oy + 7.424 * s))
        path.addLine(to: CGPoint(x: ox + 1.82 * s, y: oy + 7.493 * s))
        path.addLine(to: CGPoint(x: ox + 3.333 * s, y: oy + 7.598 * s))
        path.addLine(to: CGPoint(x: ox + 4.43 * s, y: oy + 7.662 * s))
        path.addLine(to: CGPoint(x: ox + 6.056 * s, y: oy + 7.832 * s))
        path.addLine(to: CGPoint(x: ox + 6.315 * s, y: oy + 7.832 * s))
        path.addLine(to: CGPoint(x: ox + 6.351 * s, y: oy + 7.727 * s))
        path.addLine(to: CGPoint(x: ox + 6.262 * s, y: oy + 7.662 * s))
        path.addLine(to: CGPoint(x: ox + 6.194 * s, y: oy + 7.598 * s))
        path.addLine(to: CGPoint(x: ox + 4.628 * s, y: oy + 6.536 * s))
        path.addLine(to: CGPoint(x: ox + 2.933 * s, y: oy + 5.415 * s))
        path.addLine(to: CGPoint(x: ox + 2.046 * s, y: oy + 4.769 * s))
        path.addLine(to: CGPoint(x: ox + 1.566 * s, y: oy + 4.442 * s))
        path.addLine(to: CGPoint(x: ox + 1.323 * s, y: oy + 4.136 * s))
        path.addLine(to: CGPoint(x: ox + 1.219 * s, y: oy + 3.466 * s))
        path.addLine(to: CGPoint(x: ox + 1.654 * s, y: oy + 2.986 * s))
        path.addLine(to: CGPoint(x: ox + 2.239 * s, y: oy + 3.026 * s))
        path.addLine(to: CGPoint(x: ox + 2.389 * s, y: oy + 3.066 * s))
        path.addLine(to: CGPoint(x: ox + 2.982 * s, y: oy + 3.522 * s))
        path.addLine(to: CGPoint(x: ox + 4.249 * s, y: oy + 4.503 * s))
        path.addLine(to: CGPoint(x: ox + 5.903 * s, y: oy + 5.721 * s))
        path.addLine(to: CGPoint(x: ox + 6.145 * s, y: oy + 5.923 * s))
        path.addLine(to: CGPoint(x: ox + 6.242 * s, y: oy + 5.855 * s))
        path.addLine(to: CGPoint(x: ox + 6.254 * s, y: oy + 5.806 * s))
        path.addLine(to: CGPoint(x: ox + 6.145 * s, y: oy + 5.625 * s))
        path.addLine(to: CGPoint(x: ox + 5.245 * s, y: oy + 3.999 * s))
        path.addLine(to: CGPoint(x: ox + 4.285 * s, y: oy + 2.344 * s))
        path.addLine(to: CGPoint(x: ox + 3.857 * s, y: oy + 1.658 * s))
        path.addLine(to: CGPoint(x: ox + 3.744 * s, y: oy + 1.247 * s))
        path.addLine(to: CGPoint(x: ox + 3.676 * s, y: oy + 0.763 * s))
        path.addLine(to: CGPoint(x: ox + 4.172 * s, y: oy + 0.089 * s))
        path.addLine(to: CGPoint(x: ox + 4.446 * s, y: oy + 0 * s))
        path.addLine(to: CGPoint(x: ox + 5.108 * s, y: oy + 0.089 * s))
        path.addLine(to: CGPoint(x: ox + 5.387 * s, y: oy + 0.331 * s))
        path.addLine(to: CGPoint(x: ox + 5.798 * s, y: oy + 1.271 * s))
        path.addLine(to: CGPoint(x: ox + 6.464 * s, y: oy + 2.751 * s))
        path.addLine(to: CGPoint(x: ox + 7.497 * s, y: oy + 4.765 * s))
        path.addLine(to: CGPoint(x: ox + 7.799 * s, y: oy + 5.362 * s))
        path.addLine(to: CGPoint(x: ox + 7.961 * s, y: oy + 5.915 * s))
        path.addLine(to: CGPoint(x: ox + 8.021 * s, y: oy + 6.085 * s))
        path.addLine(to: CGPoint(x: ox + 8.126 * s, y: oy + 6.085 * s))
        path.addLine(to: CGPoint(x: ox + 8.126 * s, y: oy + 5.988 * s))
        path.addLine(to: CGPoint(x: ox + 8.211 * s, y: oy + 4.854 * s))
        path.addLine(to: CGPoint(x: ox + 8.368 * s, y: oy + 3.462 * s))
        path.addLine(to: CGPoint(x: ox + 8.522 * s, y: oy + 1.67 * s))
        path.addLine(to: CGPoint(x: ox + 8.574 * s, y: oy + 1.166 * s))
        path.addLine(to: CGPoint(x: ox + 8.824 * s, y: oy + 0.561 * s))
        path.addLine(to: CGPoint(x: ox + 9.321 * s, y: oy + 0.234 * s))
        path.addLine(to: CGPoint(x: ox + 9.708 * s, y: oy + 0.42 * s))
        path.addLine(to: CGPoint(x: ox + 10.027 * s, y: oy + 0.876 * s))
        path.addLine(to: CGPoint(x: ox + 9.982 * s, y: oy + 1.17 * s))
        path.addLine(to: CGPoint(x: ox + 9.792 * s, y: oy + 2.4 * s))
        path.addLine(to: CGPoint(x: ox + 9.422 * s, y: oy + 4.33 * s))
        path.addLine(to: CGPoint(x: ox + 9.179 * s, y: oy + 5.62 * s))
        path.addLine(to: CGPoint(x: ox + 9.321 * s, y: oy + 5.62 * s))
        path.addLine(to: CGPoint(x: ox + 9.482 * s, y: oy + 5.46 * s))
        path.addLine(to: CGPoint(x: ox + 10.136 * s, y: oy + 4.592 * s))
        path.addLine(to: CGPoint(x: ox + 11.233 * s, y: oy + 3.22 * s))
        path.addLine(to: CGPoint(x: ox + 11.717 * s, y: oy + 2.675 * s))
        path.addLine(to: CGPoint(x: ox + 12.282 * s, y: oy + 2.074 * s))
        path.addLine(to: CGPoint(x: ox + 12.645 * s, y: oy + 1.787 * s))
        path.addLine(to: CGPoint(x: ox + 13.331 * s, y: oy + 1.787 * s))
        path.addLine(to: CGPoint(x: ox + 13.836 * s, y: oy + 2.538 * s))
        path.addLine(to: CGPoint(x: ox + 13.61 * s, y: oy + 3.313 * s))
        path.addLine(to: CGPoint(x: ox + 12.903 * s, y: oy + 4.208 * s))
        path.addLine(to: CGPoint(x: ox + 12.318 * s, y: oy + 4.967 * s))
        path.addLine(to: CGPoint(x: ox + 11.479 * s, y: oy + 6.097 * s))
        path.addLine(to: CGPoint(x: ox + 10.955 * s, y: oy + 7.001 * s))
        path.addLine(to: CGPoint(x: ox + 11.003 * s, y: oy + 7.073 * s))
        path.addLine(to: CGPoint(x: ox + 11.128 * s, y: oy + 7.061 * s))
        path.addLine(to: CGPoint(x: ox + 13.025 * s, y: oy + 6.658 * s))
        path.addLine(to: CGPoint(x: ox + 14.049 * s, y: oy + 6.472 * s))
        path.addLine(to: CGPoint(x: ox + 15.272 * s, y: oy + 6.262 * s))
        path.addLine(to: CGPoint(x: ox + 15.825 * s, y: oy + 6.52 * s))
        path.addLine(to: CGPoint(x: ox + 15.885 * s, y: oy + 6.783 * s))
        path.addLine(to: CGPoint(x: ox + 15.667 * s, y: oy + 7.319 * s))
        path.addLine(to: CGPoint(x: ox + 14.36 * s, y: oy + 7.642 * s))
        path.addLine(to: CGPoint(x: ox + 12.827 * s, y: oy + 7.949 * s))
        path.addLine(to: CGPoint(x: ox + 10.543 * s, y: oy + 8.489 * s))
        path.addLine(to: CGPoint(x: ox + 10.515 * s, y: oy + 8.509 * s))
        path.addLine(to: CGPoint(x: ox + 10.547 * s, y: oy + 8.549 * s))
        path.addLine(to: CGPoint(x: ox + 11.576 * s, y: oy + 8.647 * s))
        path.addLine(to: CGPoint(x: ox + 12.016 * s, y: oy + 8.671 * s))
        path.addLine(to: CGPoint(x: ox + 13.093 * s, y: oy + 8.671 * s))
        path.addLine(to: CGPoint(x: ox + 15.098 * s, y: oy + 8.821 * s))
        path.addLine(to: CGPoint(x: ox + 15.623 * s, y: oy + 9.167 * s))
        path.addLine(to: CGPoint(x: ox + 15.938 * s, y: oy + 9.591 * s))
        path.addLine(to: CGPoint(x: ox + 15.885 * s, y: oy + 9.914 * s))
        path.addLine(to: CGPoint(x: ox + 15.078 * s, y: oy + 10.325 * s))
        path.addLine(to: CGPoint(x: ox + 11.447 * s, y: oy + 9.462 * s))
        path.addLine(to: CGPoint(x: ox + 10.575 * s, y: oy + 9.244 * s))
        path.addLine(to: CGPoint(x: ox + 10.455 * s, y: oy + 9.244 * s))
        path.addLine(to: CGPoint(x: ox + 10.455 * s, y: oy + 9.317 * s))
        path.addLine(to: CGPoint(x: ox + 11.181 * s, y: oy + 10.027 * s))
        path.addLine(to: CGPoint(x: ox + 12.512 * s, y: oy + 11.229 * s))
        path.addLine(to: CGPoint(x: ox + 14.179 * s, y: oy + 12.779 * s))
        path.addLine(to: CGPoint(x: ox + 14.263 * s, y: oy + 13.162 * s))
        path.addLine(to: CGPoint(x: ox + 14.049 * s, y: oy + 13.464 * s))
        path.addLine(to: CGPoint(x: ox + 13.823 * s, y: oy + 13.432 * s))
        path.addLine(to: CGPoint(x: ox + 12.359 * s, y: oy + 12.331 * s))
        path.addLine(to: CGPoint(x: ox + 11.794 * s, y: oy + 11.834 * s))
        path.addLine(to: CGPoint(x: ox + 10.514 * s, y: oy + 10.757 * s))
        path.addLine(to: CGPoint(x: ox + 10.43 * s, y: oy + 10.757 * s))
        path.addLine(to: CGPoint(x: ox + 10.43 * s, y: oy + 10.87 * s))
        path.addLine(to: CGPoint(x: ox + 10.725 * s, y: oy + 11.302 * s))
        path.addLine(to: CGPoint(x: ox + 12.282 * s, y: oy + 13.642 * s))
        path.addLine(to: CGPoint(x: ox + 12.362 * s, y: oy + 14.36 * s))
        path.addLine(to: CGPoint(x: ox + 12.25 * s, y: oy + 14.594 * s))
        path.addLine(to: CGPoint(x: ox + 11.846 * s, y: oy + 14.735 * s))
        path.addLine(to: CGPoint(x: ox + 11.402 * s, y: oy + 14.655 * s))
        path.addLine(to: CGPoint(x: ox + 10.491 * s, y: oy + 13.375 * s))
        path.addLine(to: CGPoint(x: ox + 9.551 * s, y: oy + 11.935 * s))
        path.addLine(to: CGPoint(x: ox + 8.792 * s, y: oy + 10.644 * s))
        path.addLine(to: CGPoint(x: ox + 8.699 * s, y: oy + 10.697 * s))
        path.addLine(to: CGPoint(x: ox + 8.251 * s, y: oy + 15.518 * s))
        path.addLine(to: CGPoint(x: ox + 8.041 * s, y: oy + 15.764 * s))
        path.addLine(to: CGPoint(x: ox + 7.557 * s, y: oy + 15.95 * s))
        path.addLine(to: CGPoint(x: ox + 7.154 * s, y: oy + 15.643 * s))
        path.addLine(to: CGPoint(x: ox + 6.94 * s, y: oy + 15.147 * s))
        path.addLine(to: CGPoint(x: ox + 7.154 * s, y: oy + 14.167 * s))
        path.addLine(to: CGPoint(x: ox + 7.412 * s, y: oy + 12.887 * s))
        path.addLine(to: CGPoint(x: ox + 7.622 * s, y: oy + 11.871 * s))
        path.addLine(to: CGPoint(x: ox + 7.812 * s, y: oy + 10.608 * s))
        path.addLine(to: CGPoint(x: ox + 7.924 * s, y: oy + 10.188 * s))
        path.addLine(to: CGPoint(x: ox + 7.916 * s, y: oy + 10.16 * s))
        path.addLine(to: CGPoint(x: ox + 7.824 * s, y: oy + 10.172 * s))
        path.addLine(to: CGPoint(x: ox + 6.871 * s, y: oy + 11.479 * s))
        path.addLine(to: CGPoint(x: ox + 5.423 * s, y: oy + 13.436 * s))
        path.addLine(to: CGPoint(x: ox + 4.277 * s, y: oy + 14.663 * s))
        path.addLine(to: CGPoint(x: ox + 4.003 * s, y: oy + 14.772 * s))
        path.addLine(to: CGPoint(x: ox + 3.526 * s, y: oy + 14.525 * s))
        path.addLine(to: CGPoint(x: ox + 3.571 * s, y: oy + 14.085 * s))
        path.addLine(to: CGPoint(x: ox + 3.837 * s, y: oy + 13.695 * s))
        path.addLine(to: CGPoint(x: ox + 5.423 * s, y: oy + 11.677 * s))
        path.addLine(to: CGPoint(x: ox + 6.379 * s, y: oy + 10.427 * s))
        path.addLine(to: CGPoint(x: ox + 6.996 * s, y: oy + 9.704 * s))
        path.addLine(to: CGPoint(x: ox + 6.992 * s, y: oy + 9.599 * s))
        path.addLine(to: CGPoint(x: ox + 6.956 * s, y: oy + 9.599 * s))
        path.addLine(to: CGPoint(x: ox + 2.744 * s, y: oy + 12.335 * s))
        path.addLine(to: CGPoint(x: ox + 1.994 * s, y: oy + 12.431 * s))
        path.addLine(to: CGPoint(x: ox + 1.67 * s, y: oy + 12.129 * s))
        path.addLine(to: CGPoint(x: ox + 1.71 * s, y: oy + 11.633 * s))
        path.addLine(to: CGPoint(x: ox + 1.864 * s, y: oy + 11.471 * s))
        path.addLine(to: CGPoint(x: ox + 3.131 * s, y: oy + 10.6 * s))
        path.closeSubpath()
        return path
    }
}

private struct ModelPickerButton: View {
    @Binding var selectedModel: ClaudeModelPreset
    @State private var isHovering = false
    @State private var anchorView: NSView?

    var body: some View {
        Button {
            showMenu()
        } label: {
            HStack(spacing: 4) {
                ClaudeIconShape()
                    .fill(isHovering ? Color.primary : Color.secondary)
                    .frame(width: 12, height: 12)

                Text(selectedModel.shortDisplayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovering ? .primary : .secondary)
            }
            .frame(height: CommandMenuChromeMetrics.controlHeight)
            .padding(.horizontal, 8)
            .contentShape(
                RoundedRectangle(
                    cornerRadius: CommandMenuChromeMetrics.tabCornerRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(CommandMenuChromeButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            updateCommandMenuHoverState(hovering, state: $isHovering)
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovering {
                NSCursor.pop()
                isHovering = false
            }
        }
        .background(MenuAnchorRepresentable(anchorView: $anchorView))
        .accessibilityLabel("Model: \(selectedModel.displayName)")
    }

    private func showMenu() {
        guard let anchorView else { return }

        if isHovering {
            NSCursor.pop()
            isHovering = false
        }

        let handler = MenuActionHandler()
        objc_setAssociatedObject(anchorView, "modelMenuHandler", handler, .OBJC_ASSOCIATION_RETAIN)

        let menu = NSMenu()
        menu.autoenablesItems = false

        let iconSize = NSSize(width: 14, height: 14)

        for (index, model) in ClaudeModelPreset.menuSorted.enumerated() {
            let item = NSMenuItem(
                title: model.displayName,
                action: #selector(MenuActionHandler.performAction(_:)),
                keyEquivalent: ""
            )
            item.tag = index
            item.target = handler
            item.state = model == selectedModel ? .on : .off
            item.image = Self.claudeMenuIcon(size: iconSize)
            handler.actions[index] = { [self] in
                selectedModel = model
                AppSettings.defaultModel = model
            }
            menu.addItem(item)
        }

        let point = NSPoint(x: 0, y: anchorView.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: anchorView)
    }

    private static func claudeMenuIcon(size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let s = min(rect.width, rect.height) / 16
            let ox = rect.midX - 8 * s
            let oy = rect.midY - 8 * s

            let points: [(CGFloat, CGFloat)] = [
                (3.127, 5.396), (6.262, 7.156), (6.315, 7.309), (6.262, 7.394),
                (6.11, 7.394), (5.585, 7.426), (3.794, 7.474), (2.24, 7.539),
                (0.735, 7.619), (0.355, 7.7), (0, 8.168), (0.036, 8.402),
                (0.356, 8.616), (0.811, 8.576), (1.82, 8.507), (3.333, 8.402),
                (4.43, 8.338), (6.056, 8.168), (6.315, 8.168), (6.351, 8.273),
                (6.262, 8.338), (6.194, 8.402), (4.628, 9.464), (2.933, 10.585),
                (2.046, 11.231), (1.566, 11.558), (1.323, 11.864), (1.219, 12.534),
                (1.654, 13.014), (2.239, 12.974), (2.389, 12.934), (2.982, 12.478),
                (4.249, 11.497), (5.903, 10.279), (6.145, 10.077), (6.242, 10.145),
                (6.254, 10.194), (6.145, 10.375), (5.245, 12.001), (4.285, 13.656),
                (3.857, 14.342), (3.744, 14.753), (3.676, 15.237), (4.172, 15.911),
                (4.446, 16), (5.108, 15.911), (5.387, 15.669), (5.798, 14.729),
                (6.464, 13.249), (7.497, 11.235), (7.799, 10.638), (7.961, 10.085),
                (8.021, 9.915), (8.126, 9.915), (8.126, 10.012), (8.211, 11.146),
                (8.368, 12.538), (8.522, 14.33), (8.574, 14.834), (8.824, 15.439),
                (9.321, 15.766), (9.708, 15.58), (10.027, 15.124), (9.982, 14.83),
                (9.792, 13.6), (9.422, 11.67), (9.179, 10.38), (9.321, 10.38),
                (9.482, 10.54), (10.136, 11.408), (11.233, 12.78), (11.717, 13.325),
                (12.282, 13.926), (12.645, 14.213), (13.331, 14.213), (13.836, 13.462),
                (13.61, 12.687), (12.903, 11.792), (12.318, 11.033), (11.479, 9.903),
                (10.955, 8.999), (11.003, 8.927), (11.128, 8.939), (13.025, 9.342),
                (14.049, 9.528), (15.272, 9.738), (15.825, 9.48), (15.885, 9.217),
                (15.667, 8.681), (14.36, 8.358), (12.827, 8.051), (10.543, 7.511),
                (10.515, 7.491), (10.547, 7.451), (11.576, 7.353), (12.016, 7.329),
                (13.093, 7.329), (15.098, 7.179), (15.623, 6.833), (15.938, 6.409),
                (15.885, 6.086), (15.078, 5.675), (11.447, 6.538), (10.575, 6.756),
                (10.455, 6.756), (10.455, 6.683), (11.181, 5.973), (12.512, 4.771),
                (14.179, 3.221), (14.263, 2.838), (14.049, 2.536), (13.823, 2.568),
                (12.359, 3.669), (11.794, 4.166), (10.514, 5.243), (10.43, 5.243),
                (10.43, 5.13), (10.725, 4.698), (12.282, 2.358), (12.362, 1.64),
                (12.25, 1.406), (11.846, 1.265), (11.402, 1.345), (10.491, 2.625),
                (9.551, 4.065), (8.792, 5.356), (8.699, 5.303), (8.251, 0.482),
                (8.041, 0.236), (7.557, 0.05), (7.154, 0.357), (6.94, 0.853),
                (7.154, 1.833), (7.412, 3.113), (7.622, 4.129), (7.812, 5.392),
                (7.924, 5.812), (7.916, 5.84), (7.824, 5.828), (6.871, 4.521),
                (5.423, 2.564), (4.277, 1.337), (4.003, 1.228), (3.526, 1.475),
                (3.571, 1.915), (3.837, 2.305), (5.423, 4.323), (6.379, 5.573),
                (6.996, 6.296), (6.992, 6.401), (6.956, 6.401), (2.744, 3.665),
                (1.994, 3.569), (1.67, 3.871), (1.71, 4.367), (1.864, 4.529),
                (3.131, 5.4),
            ]

            context.move(to: CGPoint(x: ox + points[0].0 * s, y: oy + points[0].1 * s))
            for i in 1..<points.count {
                context.addLine(to: CGPoint(x: ox + points[i].0 * s, y: oy + points[i].1 * s))
            }
            context.closePath()

            NSColor.labelColor.setFill()
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}

private struct HeaderToggleButton: View {
    let icon: String
    let label: String
    let isOn: Bool
    var isVisible: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    private static let activeForeground = Color.blue

    var body: some View {
        if isVisible {
            Button(action: action) {
                HStack(spacing: 3) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))

                    if isOn {
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .foregroundStyle(isOn ? Self.activeForeground : (isHovering ? .primary : .secondary))
                .frame(height: CommandMenuChromeMetrics.controlHeight)
                .padding(.horizontal, isOn ? 8 : 6)
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: CommandMenuChromeMetrics.tabCornerRadius,
                        style: .continuous
                    )
                )
            }
            .buttonStyle(HeaderToggleButtonStyle(isHovering: isHovering, isOn: isOn))
            .onHover { hovering in
                updateCommandMenuHoverState(hovering, state: $isHovering)
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isOn)
            .accessibilityLabel("\(label): \(isOn ? "on" : "off")")
        }
    }
}

private struct HeaderToggleButtonStyle: ButtonStyle {
    var isHovering: Bool
    var isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(
                    cornerRadius: CommandMenuChromeMetrics.tabCornerRadius,
                    style: .continuous
                )
                .fill(isOn
                    ? Color.blue.opacity(configuration.isPressed ? 0.28 : (isHovering ? 0.22 : 0.15))
                    : Color.black.opacity(configuration.isPressed ? 0.14 : (isHovering ? 0.06 : 0))
                )
            )
    }
}

private struct SettingsMenuButton: View {

    @State private var isHovering = false
    @State private var anchorView: NSView?

    var body: some View {
        Button {
            showMenu()
        } label: {
            Group {
                if let img = Self.loadTemplateIcon() {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
            .foregroundStyle(isHovering ? .primary : .secondary)
            .frame(
                width: CommandMenuChromeMetrics.controlWidth,
                height: CommandMenuChromeMetrics.controlHeight
            )
        }
        .buttonStyle(CommandMenuChromeButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            updateCommandMenuHoverState(hovering, state: $isHovering)
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if isHovering {
                NSCursor.pop()
                isHovering = false
            }
        }
        .background(MenuAnchorRepresentable(anchorView: $anchorView))
    }

    private static func loadTemplateIcon() -> NSImage? {
        let candidates: [() -> NSImage?] = [
            { Bundle.main.image(forResource: "StatusBarIcon") },
            {
                let url = Bundle.main.resourceURL?
                    .appendingPathComponent("This_This.bundle")
                    .appendingPathComponent("StatusBarIcon.png")
                return url.flatMap { NSImage(contentsOf: $0) }
            },
            {
                let url = Bundle.main.executableURL?.deletingLastPathComponent()
                    .appendingPathComponent("This_This.bundle")
                    .appendingPathComponent("StatusBarIcon.png")
                return url.flatMap { NSImage(contentsOf: $0) }
            },
        ]
        for candidate in candidates {
            if let img = candidate() {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }

    private func showMenu() {
        guard let anchorView else { return }

        if isHovering {
            NSCursor.pop()
            isHovering = false
        }

        let handler = MenuActionHandler()
        objc_setAssociatedObject(anchorView, "menuHandler", handler, .OBJC_ASSOCIATION_RETAIN)

        let menu = NSMenu()
        menu.autoenablesItems = false

        // Toggle settings
        let toggles: [(String, Bool, Int)] = [
            ("Sound Effects", AppSettings.chimeEnabled, 100),
            ("Object Highlighting", AppSettings.highlightOverlayEnabled, 101),
            ("Object Text", AppSettings.objectTextEnabled, 102),
            ("Auto-Voice", AppSettings.autoVoiceEnabled, 103),
            ("Structured UI", AppSettings.structuredUIEnabled, 104),
        ]

        for (title, isOn, tag) in toggles {
            let item = NSMenuItem(title: title, action: #selector(MenuActionHandler.performAction(_:)), keyEquivalent: "")
            item.tag = tag
            item.target = handler
            item.state = isOn ? .on : .off
            handler.actions[tag] = {
                switch tag {
                case 100: AppSettings.chimeEnabled = !AppSettings.chimeEnabled
                case 101: AppSettings.highlightOverlayEnabled = !AppSettings.highlightOverlayEnabled
                case 102: AppSettings.objectTextEnabled = !AppSettings.objectTextEnabled
                case 103: AppSettings.autoVoiceEnabled = !AppSettings.autoVoiceEnabled
                case 104: AppSettings.structuredUIEnabled = !AppSettings.structuredUIEnabled
                default: break
                }
            }
            menu.addItem(item)
        }

        let point = NSPoint(x: 0, y: anchorView.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: anchorView)
    }
}

private struct CommandMenuChromeButtonStyle: ButtonStyle {
    var isHovering: Bool
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(
                    cornerRadius: CommandMenuChromeMetrics.tabCornerRadius,
                    style: .continuous
                )
                    .fill(Color.black.opacity(
                        configuration.isPressed ? 0.14 : (isActive ? 0.12 : (isHovering ? 0.06 : 0))
                    ))
            )
    }
}

private struct CommandMenuContentFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct CommandMenuSurfaceHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CommandMenuMinimizeCloseButton: View {
    let isExpanded: Bool
    let onMinimize: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            if isExpanded {
                onMinimize()
            } else {
                onClose()
            }
        } label: {
            Image(systemName: isExpanded ? "minus" : "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(
                    width: CommandMenuChromeMetrics.controlWidth,
                    height: CommandMenuChromeMetrics.controlHeight
                )
        }
        .buttonStyle(CommandMenuChromeButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            updateCommandMenuHoverState(hovering, state: $isHovering)
        }
        .help(isExpanded ? "Minimize" : "Close")
    }
}

private struct CommandMenuPinButton: View {
    @Binding var isPinned: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            isPinned.toggle()
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle((isPinned || isHovering) ? .primary : .secondary)
                .frame(
                    width: CommandMenuChromeMetrics.controlWidth,
                    height: CommandMenuChromeMetrics.controlHeight
                )
        }
        .buttonStyle(CommandMenuChromeButtonStyle(isHovering: isHovering, isActive: isPinned))
        .onHover { hovering in
            updateCommandMenuHoverState(hovering, state: $isHovering)
        }
        .help(
            isPinned
                ? "Unpin (outside clicks or Space switches will dismiss)"
                : "Pin (keep open across outside clicks and Space switches)"
        )
    }
}

private struct CommandMenuResetHeightButton: View {
    let onReset: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: onReset) {
            Image(systemName: "rectangle.expand.vertical")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(
                    width: CommandMenuChromeMetrics.controlWidth,
                    height: CommandMenuChromeMetrics.controlHeight
                )
        }
        .buttonStyle(CommandMenuChromeButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            updateCommandMenuHoverState(hovering, state: $isHovering)
        }
        .help("Reset height")
    }
}

private extension View {
    func reportHeight<Key: PreferenceKey>(_ key: Key.Type) -> some View where Key.Value == CGFloat {
        background(
            GeometryReader { geometry in
                Color.clear.preference(key: key, value: geometry.size.height)
            }
        )
    }
}
