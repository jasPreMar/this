import AppKit
import MarkdownUI
import SwiftUI

final class CommandMenuPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onClickOutsideContent: (() -> Void)?
    var isPinned = false

    private var hostingView: NSHostingView<AnyView>?
    private var passthrough: CommandMenuPassthroughView?

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

    func fillScreen(_ screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }

    /// Called by SwiftUI when the visible content frame changes (in window coordinates).
    func updateContentFrame(_ rect: CGRect) {
        passthrough?.contentFrame = rect
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

        contentView = passthrough
    }
}

/// Custom NSView that passes mouse clicks through to apps behind when
/// they land outside the visible command-menu content area.
private final class CommandMenuPassthroughView: NSView {
    weak var panel: CommandMenuPanel?
    var contentFrame: CGRect = .zero

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
}

struct CommandMenuView: View {
    private static let panelWidth: CGFloat = 720
    private static let maxChatHeight: CGFloat = 500
    private static let fallbackInputRowHeight: CGFloat = 54
    private static let fallbackBottomBarHeight: CGFloat = 48
    private static let fallbackTabBarHeight: CGFloat = 44
    private static let dividerHeight: CGFloat = 1
    private static let bottomMargin: CGFloat = 80

    @ObservedObject var appDelegate: AppDelegate
    let presentationID: UUID
    @State private var isContentVisible = false
    @State private var textWidth: CGFloat = FocusedTextField.minWidth
    @State private var textHeight: CGFloat = 20
    @State private var inputRowHeight: CGFloat = Self.fallbackInputRowHeight
    @State private var tabBarHeight: CGFloat = Self.fallbackTabBarHeight
    @State private var chatContentHeight: CGFloat = 0

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
        appDelegate.commandMenuChatRecord != nil
    }

    private var activeChatRecord: TaskSessionRecord? {
        appDelegate.commandMenuChatRecord
    }


    private var hasTasks: Bool {
        !tabs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 0) {
                titleBar

                Divider()

                headerRow

                Divider()

                if isExpanded {
                    chatSection

                    Divider()
                }

                inputRow
            }
            .frame(width: Self.panelWidth)
            .modifier(CommandMenuSurfaceChrome(usesNativeGlassSurface: usesNativeGlassSurface))
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 5)
            .opacity(isContentVisible ? 1 : 0)
            .blur(radius: isContentVisible ? 0 : 10)
            .offset(y: isContentVisible ? 0 : 8)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: CommandMenuContentFramePreferenceKey.self,
                        value: geometry.frame(in: .global)
                    )
                }
            )
            .padding(.bottom, Self.bottomMargin)
            .animation(.easeInOut(duration: 0.25), value: isExpanded)
        }
        .id(presentationID)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(CommandMenuContentFramePreferenceKey.self) { frame in
            appDelegate.updateCommandMenuContentFrame(frame)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25)) {
                isContentVisible = true
            }
        }
        .onChange(of: appDelegate.commandMenuDismissing) { _, dismissing in
            guard dismissing else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                isContentVisible = false
            }
        }
    }

    private var titleBar: some View {
        HStack(spacing: 0) {
            SettingsMenuButton(
                onCheckForUpdates: { appDelegate.checkForUpdatesFromCommandMenu() },
                onLeaveFeedback: { openFeedback() },
                onSettings: { openSettings() },
                onQuit: { appDelegate.quitFromCommandMenu() }
            )
            .padding(.leading, 12)

            Spacer(minLength: 0)

            HStack(spacing: 1) {
                CommandMenuPinButton(isPinned: $appDelegate.commandMenuPinned)

                CommandMenuMinimizeCloseButton(
                    isExpanded: isExpanded,
                    onMinimize: {
                        appDelegate.handleCommandMenuBackNavigation()
                        query = ""
                    },
                    onClose: { appDelegate.closeCommandMenu() }
                )
            }
            .padding(.trailing, 12)
        }
        .frame(height: Self.fallbackBottomBarHeight)
        .background(Color.black.opacity(0.035))
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            if hasTasks {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tabs) { task in
                                CommandMenuTabButton(
                                    task: task,
                                    isSelected: activeChatRecord?.id == task.id,
                                    onTap: { toggleTab(task) }
                                )
                                .id(task.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: activeChatRecord?.id) { _, newID in
                        guard let newID else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            } else {
                Spacer(minLength: 0)
            }

            if isExpanded {
                Button(action: {
                    appDelegate.handleCommandMenuBackNavigation()
                    query = ""
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
            }
        }
        .reportHeight(CommandMenuTabBarHeightPreferenceKey.self)
        .onPreferenceChange(CommandMenuTabBarHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            tabBarHeight = height
        }
    }

    @ViewBuilder
    private var chatSection: some View {
        if let chatRecord = activeChatRecord,
           let viewModel = chatRecord.panel?.searchViewModel {
            CommandMenuChatSection(
                viewModel: viewModel,
                contentHeight: $chatContentHeight
            )
            .frame(maxHeight: Self.maxChatHeight)
            .clipped()
        }
    }

    private var inputRow: some View {
        CommandMenuTextInputRow(
            text: $appDelegate.commandMenuQuery,
            textWidth: $textWidth,
            textHeight: $textHeight,
            placeholder: isExpanded ? "Message this task..." : "Ask Claude Code anything…",
            voiceState: appDelegate.commandMenuVoiceState,
            voiceLevel: appDelegate.commandMenuVoiceLevel,
            isStreaming: activeChatRecord?.isRunning == true,
            onSubmit: submitInput,
            onStop: stopActiveTask,
            onVoice: { self.appDelegate.toggleCommandMenuVoice() },
            onKeyDown: handleInputKeyDown
        )
        .reportHeight(CommandMenuInputRowHeightPreferenceKey.self)
        .onPreferenceChange(CommandMenuInputRowHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            inputRowHeight = height
        }
    }


    private func switchToPreviousTab() {
        guard !tabs.isEmpty else { return }
        guard let currentID = activeChatRecord?.id,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentID }) else {
            if let last = tabs.last {
                appDelegate.openTaskRecord(last)
            }
            return
        }
        let previousIndex = currentIndex > 0 ? currentIndex - 1 : tabs.count - 1
        appDelegate.openTaskRecord(tabs[previousIndex])
    }

    private func switchToNextTab() {
        guard !tabs.isEmpty else { return }
        guard let currentID = activeChatRecord?.id,
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
        case 33: // [
            if hasCommand && hasShift {
                switchToPreviousTab()
                return true
            }
        case 30: // ]
            if hasCommand && hasShift {
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
    @Binding var contentHeight: CGFloat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    chatTranscript
                    Spacer(minLength: 0)
                }
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: CommandMenuChatContentHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                    }
                )
            }
            .onAppear {
                proxy.scrollTo("chatBottom", anchor: .bottom)
            }
            .onChange(of: viewModel.claudeManager?.outputText) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("chatBottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.chatHistory.count) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("chatBottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.claudeManager?.events.count) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("chatBottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.claudeManager?.status) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("chatBottom", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.claudeManager?.activeToolName) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("chatBottom", anchor: .bottom)
                }
            }
        }
        .onPreferenceChange(CommandMenuChatContentHeightPreferenceKey.self) { height in
            contentHeight = height
        }
    }

    private var chatTranscript: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(viewModel.chatHistory) { entry in
                if entry.role == "user" {
                    HStack {
                        Spacer(minLength: 40)
                        Text(entry.text)
                            .font(.system(size: 13))
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

private struct CommandMenuTabButton: View {
    @ObservedObject var task: TaskSessionRecord
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    private var backgroundOpacity: Double {
        if isSelected { return 0.12 }
        if isHovering { return 0.06 }
        return 0
    }

    var body: some View {
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(backgroundOpacity))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct CommandMenuChatContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CommandMenuTabBarHeightPreferenceKey: PreferenceKey {
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

    private var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .leading) {
                Text(placeholder)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .opacity(text.isEmpty ? 1 : 0)
                    .allowsHitTesting(false)

                FocusedTextField(
                    text: $text,
                    textWidth: $textWidth,
                    textHeight: $textHeight,
                    onSubmit: onSubmit,
                    onKeyDown: onKeyDown,
                    font: .systemFont(ofSize: 17, weight: .regular)
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
        .padding(.horizontal, 18)
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
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
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
            .foregroundStyle(.secondary)
            .frame(width: 32, height: 28)
        }
        .buttonStyle(SettingsMenuButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            isHovering = hovering
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

private struct SettingsMenuButtonStyle: ButtonStyle {
    var isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(
                        configuration.isPressed ? 0.14 : (isHovering ? 0.08 : 0)
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
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 28)
        }
        .buttonStyle(SettingsMenuButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            isHovering = hovering
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
                .foregroundStyle(isPinned ? .primary : .secondary)
                .frame(width: 32, height: 28)
        }
        .buttonStyle(SettingsMenuButtonStyle(isHovering: isHovering))
        .onHover { hovering in
            isHovering = hovering
        }
        .help(isPinned ? "Unpin (click outside will not dismiss)" : "Pin (keep open while clicking elsewhere)")
    }
}

private struct CommandMenuInputRowHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
