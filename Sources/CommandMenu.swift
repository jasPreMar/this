import AppKit
import MarkdownUI
import SwiftUI

final class CommandMenuPanel: NSPanel {
    private static let nativeGlassCornerRadius: CGFloat = 20

    var onEscape: (() -> Void)?
    private var dragStartMonitor: Any?
    private var pendingDragEvent: NSEvent?
    private var restingOrigin: NSPoint?
    private var snapBackThreshold: CGFloat = 0
    private var shouldSnapBackToRestingOrigin = false
    private var hostingView: NSHostingView<AnyView>?
    private var glassEffectView: NSView?

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

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
    }

    override func orderOut(_ sender: Any?) {
        cancelPendingDrag()
        super.orderOut(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    func setRestingOrigin(
        _ origin: NSPoint,
        snapBackEnabled: Bool,
        snapBackThreshold: CGFloat = 84
    ) {
        restingOrigin = origin
        shouldSnapBackToRestingOrigin = snapBackEnabled
        self.snapBackThreshold = snapBackThreshold
    }

    private func cancelPendingDrag() {
        if let dragStartMonitor {
            NSEvent.removeMonitor(dragStartMonitor)
            self.dragStartMonitor = nil
        }
        pendingDragEvent = nil
    }

    private func installSurfaceIfNeeded() {
        guard let hostingView else { return }

        isOpaque = false
        backgroundColor = .clear
        contentView = hostingView
        hasShadow = true
    }

    private func snapBackIfNeeded() {
        guard shouldSnapBackToRestingOrigin,
              let restingOrigin else { return }

        let dragDistance = hypot(frame.minX - restingOrigin.x, frame.minY - restingOrigin.y)
        guard dragDistance <= snapBackThreshold else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            animator().setFrameOrigin(restingOrigin)
        }
    }

}

struct CommandMenuView: View {
    private static let panelWidth: CGFloat = 720
    private static let maxPanelHeight: CGFloat = 520
    private static let fallbackInputRowHeight: CGFloat = 54
    private static let fallbackBottomBarHeight: CGFloat = 48
    private static let dividerHeight: CGFloat = 1
    private static let taskListVerticalPadding: CGFloat = 8


    @ObservedObject var appDelegate: AppDelegate
    let presentationID: UUID
    @State private var query = ""
    @State private var selectedTaskID: TaskSessionRecord.ID?
    @State private var hoveredTaskID: TaskSessionRecord.ID?
    @State private var hoverSelectionEnabled = false
    @State private var boundaryExitDirection: Int?
    @State private var textWidth: CGFloat = FocusedTextField.minWidth
    @State private var textHeight: CGFloat = 20
    @State private var inputRowHeight: CGFloat = Self.fallbackInputRowHeight
    @State private var bottomBarHeight: CGFloat = Self.fallbackBottomBarHeight

    private var usesNativeGlassSurface: Bool {
        false
    }

    private var sortedTasks: [TaskSessionRecord] {
        appDelegate.taskRecords.sorted { lhs, rhs in
            if lhs.lastActivityAt == rhs.lastActivityAt {
                return lhs.startedAt > rhs.startedAt
            }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
    }

    private var displayedTasks: [TaskSessionRecord] {
        sortedTasks.reversed()
    }

    private var selectedTask: TaskSessionRecord? {
        guard let selectedTaskID else { return nil }
        return sortedTasks.first(where: { $0.id == selectedTaskID })
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var queryIsEmpty: Bool {
        trimmedQuery.isEmpty
    }

    private var footerShortcuts: [CommandMenuShortcutItem] {
        var shortcuts: [CommandMenuShortcutItem]

        if queryIsEmpty {
            shortcuts = []

            if let selectedTask {
                shortcuts.append(CommandMenuShortcutItem(label: "Open", keys: ["↩"]))

                if selectedTask.isRunning {
                    shortcuts.append(CommandMenuShortcutItem(label: "Stop", keys: ["⌫"]))
                }

                shortcuts.append(CommandMenuShortcutItem(label: "Delete", keys: ["⌘", "⌫"]))
            }
        } else {
            shortcuts = [
                CommandMenuShortcutItem(label: "Run", keys: ["↩"]),
                CommandMenuShortcutItem(label: "Send Feedback", keys: ["⌘", "⇧", "↩"])
            ]
        }

        if hasRunningTasks {
            shortcuts.append(CommandMenuShortcutItem(label: "Kill All", keys: ["⌘", "⇧", "⌫"]))
        }

        return shortcuts
    }

    private var hasTasks: Bool {
        !sortedTasks.isEmpty
    }

    private var hasRunningTasks: Bool {
        sortedTasks.contains(where: \.isRunning)
    }

    private var hasVisibleList: Bool {
        hasTasks
    }

    private var dividerCount: CGFloat {
        hasVisibleList ? 2 : 1
    }

    private var chromeHeight: CGFloat {
        inputRowHeight + bottomBarHeight + (dividerCount * Self.dividerHeight)
    }

    private var maxTaskSectionHeight: CGFloat {
        max(Self.maxPanelHeight - chromeHeight, 0)
    }

    private var targetTaskSectionHeight: CGFloat {
        maxTaskSectionHeight / 2
    }

    private var listSectionHeight: CGFloat {
        hasVisibleList ? targetTaskSectionHeight : 0
    }

    private var desiredPanelHeight: CGFloat {
        if appDelegate.commandMenuChatRecord != nil {
            Self.maxPanelHeight
        } else {
            chromeHeight + listSectionHeight
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let chatRecord = appDelegate.commandMenuChatRecord,
                   let viewModel = chatRecord.panel?.searchViewModel {
                    CommandMenuChatDetailView(
                        task: chatRecord,
                        viewModel: viewModel,
                        onBack: { appDelegate.handleCommandMenuBackNavigation() }
                    )
                } else {
                    taskListContent
                }
            }
        }
        .id(presentationID)
        .frame(width: Self.panelWidth)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .modifier(CommandMenuSurfaceChrome(usesNativeGlassSurface: usesNativeGlassSurface))
        .onAppear {
            syncPanelSize()
        }
        .onChange(of: desiredPanelHeight) { _, _ in
            syncPanelSize()
        }
    }

    private var taskListContent: some View {
        VStack(spacing: 0) {
            bottomBar

            Divider()

            if hasVisibleList {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(displayedTasks) { task in
                                CommandMenuTaskRow(
                                    task: task,
                                    isSelected: task.id == selectedTaskID,
                                    isHovered: task.id == hoveredTaskID,
                                    onHover: { if hoverSelectionEnabled { hoveredTaskID = task.id } },
                                    onHoverEnd: { if hoveredTaskID == task.id { hoveredTaskID = nil } },
                                    onOpen: { open(task) }
                                )
                                .id(task.id)
                            }
                        }
                        .padding(.vertical, Self.taskListVerticalPadding)
                    }
                    .onAppear {
                        guard let bottomTaskID = displayedTasks.last?.id else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo(bottomTaskID, anchor: .bottom)
                        }
                    }
                    .onChange(of: selectedTaskID) { _, newID in
                        guard let newID else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                    .onChange(of: displayedTasks.map(\.id)) { _, _ in
                        guard selectedTaskID == nil,
                              let bottomTaskID = displayedTasks.last?.id else { return }
                        DispatchQueue.main.async {
                            proxy.scrollTo(bottomTaskID, anchor: .bottom)
                        }
                    }
                }
                .frame(height: listSectionHeight, alignment: .top)

                Divider()
            }

            inputRow
        }
        .onAppear {
            hoverSelectionEnabled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                hoverSelectionEnabled = true
            }
        }
        .onChange(of: sortedTasks.map(\.id)) { _, _ in
            guard queryIsEmpty else { return }
            if let selectedTaskID,
               !sortedTasks.contains(where: { $0.id == selectedTaskID }) {
                self.selectedTaskID = nil
            }
        }
        .onChange(of: queryIsEmpty) { _, _ in
            selectedTaskID = nil
            boundaryExitDirection = nil
        }
    }

    private var inputRow: some View {
        CommandMenuTextInputRow(
            text: $query,
            textWidth: $textWidth,
            textHeight: $textHeight,
            placeholder: "Start a new task from your Home folder...",
            voiceState: appDelegate.commandMenuVoiceState,
            voiceLevel: appDelegate.commandMenuVoiceLevel,
            onSubmit: submitInput,
            onKeyDown: handleInputKeyDown
        )
        .reportHeight(CommandMenuInputRowHeightPreferenceKey.self)
        .onPreferenceChange(CommandMenuInputRowHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            inputRowHeight = height
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            SettingsMenuButton(
                onCheckForUpdates: { appDelegate.checkForUpdatesFromCommandMenu() },
                onLeaveFeedback: { openFeedback() },
                onSettings: { openSettings() },
                onQuit: { appDelegate.quitFromCommandMenu() }
            )

            Spacer(minLength: 16)

            ForEach(footerShortcuts) { shortcut in
                CommandMenuShortcut(label: shortcut.label, keys: shortcut.keys)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.035))
        .reportHeight(CommandMenuBottomBarHeightPreferenceKey.self)
        .onPreferenceChange(CommandMenuBottomBarHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            bottomBarHeight = height
        }
    }

    private func submitInput() {
        if queryIsEmpty {
            openSelectedTask()
        } else {
            if appDelegate.launchTaskFromCommandMenu(query: trimmedQuery) != nil {
                query = ""
            }
        }
    }

    private func syncPanelSize() {
        guard desiredPanelHeight > 0 else { return }
        appDelegate.updateCommandMenuSize(
            CGSize(
                width: Self.panelWidth,
                height: ceil(desiredPanelHeight)
            )
        )
    }

    private func handleInputKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = modifiers.contains(.command)
        let hasShift = modifiers.contains(.shift)

        switch event.keyCode {
        case 125:
            moveTaskSelection(by: 1)
            return true
        case 126:
            moveTaskSelection(by: -1)
            return true
        case 36, 76:
            if hasCommand && hasShift && !queryIsEmpty {
                sendQueryAsFeedback()
                return true
            }

            submitInput()
            return true
        case 51:
            if hasCommand && hasShift {
                guard hasRunningTasks else { return false }
                killAllRunningTasks()
                return true
            }

            if hasCommand, queryIsEmpty {
                deleteSelectedTask()
                return true
            }

            if modifiers.isEmpty, queryIsEmpty {
                stopSelectedTask()
                return true
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
        default:
            break
        }

        return false
    }

    private func selectFirstTaskIfNeeded() {
        selectedTaskID = displayedTasks.last?.id
        boundaryExitDirection = nil
    }

    private func moveTaskSelection(by delta: Int) {
        guard !displayedTasks.isEmpty else { return }
        guard let currentSelectionID = selectedTaskID,
              let currentIndex = displayedTasks.firstIndex(where: { $0.id == currentSelectionID }) else {
            if boundaryExitDirection == delta {
                return
            }
            selectedTaskID = delta < 0 ? displayedTasks.last?.id : displayedTasks.first?.id
            boundaryExitDirection = nil
            return
        }

        if (delta < 0 && currentIndex == 0) ||
            (delta > 0 && currentIndex == displayedTasks.count - 1) {
            selectedTaskID = nil
            boundaryExitDirection = delta
            return
        }

        let nextIndex = min(max(currentIndex + delta, 0), displayedTasks.count - 1)
        selectedTaskID = displayedTasks[nextIndex].id
        boundaryExitDirection = nil
    }

    private func openSelectedTask() {
        guard let selectedTask else { return }
        open(selectedTask)
    }

    private func open(_ task: TaskSessionRecord) {
        appDelegate.openTaskRecord(task)
    }

    private func stopSelectedTask() {
        guard let selectedTask else { return }
        appDelegate.stopTaskRecord(selectedTask)
    }

    private func deleteSelectedTask() {
        guard let selectedTask else { return }
        appDelegate.deleteTaskRecord(selectedTask)
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

private struct CommandMenuTaskRow: View {
    @ObservedObject var task: TaskSessionRecord
    let isSelected: Bool
    let isHovered: Bool
    let onHover: () -> Void
    let onHoverEnd: () -> Void
    let onOpen: () -> Void

    private var backgroundOpacity: Double {
        if isSelected { return 0.08 }
        if isHovered { return 0.04 }
        return 0
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                taskIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !task.subtitle.isEmpty {
                        Text(task.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 16)

                if let startedAt = task.currentStreamStartedAt {
                    ActiveStreamBadgeView(startedAt: startedAt)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(backgroundOpacity))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { isHovering in
            if isHovering {
                onHover()
            } else {
                onHoverEnd()
            }
        }
    }

    @ViewBuilder
    private var taskIcon: some View {
        if let icon = task.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.06))
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: "app")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
        }
    }
}

private struct CommandMenuChatDetailView: View {
    @ObservedObject var task: TaskSessionRecord
    @ObservedObject var viewModel: SearchViewModel
    let onBack: () -> Void

    @State private var chatTextWidth: CGFloat = FocusedTextField.minWidth
    @State private var chatTextHeight: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            chatHeader

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        chatTranscript
                        Spacer(minLength: 0)
                    }
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

            Divider()

            CommandMenuTextInputRow(
                text: $viewModel.query,
                textWidth: $chatTextWidth,
                textHeight: $chatTextHeight,
                placeholder: "Message this task...",
                voiceState: viewModel.voiceState,
                voiceLevel: viewModel.voiceLevel,
                onSubmit: {
                    viewModel.submitMessage()
                }
            )
        }
        .frame(height: 520)
    }

    private var chatHeader: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if let icon = task.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }

            Text(task.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var chatTranscript: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(viewModel.chatHistory) { entry in
                if entry.role == "user" {
                    Text("> \(entry.text)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
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

private struct CommandMenuTextInputRow: View {
    @Binding var text: String
    @Binding var textWidth: CGFloat
    @Binding var textHeight: CGFloat
    let placeholder: String
    let voiceState: SearchViewModel.VoiceState
    let voiceLevel: CGFloat
    let onSubmit: () -> Void
    var onKeyDown: ((NSEvent) -> Bool)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }

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
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

private struct CommandMenuShortcut: View {
    let label: String
    let keys: [String]

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary)

            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(0.08))
                        )
                }
            }
        }
    }
}

private struct CommandMenuShortcutItem: Identifiable {
    let label: String
    let keys: [String]

    var id: String {
        "\(label)-\(keys.joined())"
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
            Image(systemName: "gearshape.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
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

private struct CommandMenuInputRowHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CommandMenuBottomBarHeightPreferenceKey: PreferenceKey {
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
