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
            SettingsMenuButton(
                onCheckForUpdates: { appDelegate.checkForUpdatesFromCommandMenu() },
                onLeaveFeedback: { openFeedback() },
                onSettings: { openSettings() },
                onQuit: { appDelegate.quitFromCommandMenu() }
            )
            .padding(.leading, CommandMenuChromeMetrics.edgePadding)

            if canResizeFromHeader {
                headerResizeArea(screenHeight: screenHeight)
            } else {
                Spacer(minLength: 0)
            }

            HStack(spacing: 1) {
                CommandMenuPinButton(isPinned: $appDelegate.commandMenuPinned)

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
            voiceLevel: appDelegate.commandMenuVoiceLevel,
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
    let voiceLevel: CGFloat
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
        HStack(spacing: 12) {
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

            VoiceTrailingIndicator(
                state: voiceState,
                level: voiceLevel
            )

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

    @State private var isHovering = false

    private var isVoiceActive: Bool {
        switch voiceState {
        case .listening, .transcribing:
            return true
        case .idle, .failed:
            return false
        }
    }

    var body: some View {
        Group {
            if isStreaming {
                actionButton(
                    icon: "stop.fill",
                    action: onStop,
                    accessibilityLabel: "Stop"
                )
            } else if hasText {
                actionButton(
                    icon: "arrow.up",
                    action: onSubmit,
                    accessibilityLabel: "Send"
                )
            } else {
                actionButton(
                    icon: isVoiceActive ? "mic.fill" : "mic",
                    action: onVoice,
                    accessibilityLabel: "Voice input"
                )
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isStreaming)
        .animation(.easeInOut(duration: 0.15), value: hasText)
    }

    private func actionButton(icon: String, action: @escaping () -> Void, accessibilityLabel: String) -> some View {
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
        .transition(.opacity)
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

private struct SettingsMenuButton: View {
    let onCheckForUpdates: () -> Void
    let onLeaveFeedback: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

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

        let items: [(String, String, Int, () -> Void)] = [
            ("Check for Updates", "u", 0, onCheckForUpdates),
            ("Leave Feedback", "l", 1, onLeaveFeedback),
            ("Settings", ",", 2, onSettings),
        ]

        for (title, keyEquiv, tag, action) in items {
            let item = NSMenuItem(title: title, action: #selector(MenuActionHandler.performAction(_:)), keyEquivalent: keyEquiv)
            item.tag = tag
            item.target = handler
            handler.actions[tag] = action
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit This", action: #selector(MenuActionHandler.performAction(_:)), keyEquivalent: "q")
        quitItem.tag = 3
        quitItem.target = handler
        handler.actions[3] = onQuit
        menu.addItem(quitItem)

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
