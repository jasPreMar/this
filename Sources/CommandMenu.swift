import AppKit
import MarkdownUI
import SwiftUI

final class CommandMenuPanel: NSPanel {
    var onEscape: (() -> Void)?
    private var dragStartMonitor: Any?
    private var pendingDragEvent: NSEvent?
    private var restingOrigin: NSPoint?
    private var snapBackThreshold: CGFloat = 0
    private var shouldSnapBackToRestingOrigin = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            cancelPendingDrag()
            let hit = contentView?.hitTest(event.locationInWindow)
            if !isScrollOrTextInput(hit) {
                pendingDragEvent = event
                dragStartMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDragged, .leftMouseUp]
                ) { [weak self] nextEvent in
                    guard let self else { return nextEvent }
                    if nextEvent.type == .leftMouseDragged,
                       let original = self.pendingDragEvent {
                        self.cancelPendingDrag()
                        self.performDrag(with: original)
                        self.snapBackIfNeeded()
                        return nil
                    }
                    if nextEvent.type == .leftMouseUp {
                        self.cancelPendingDrag()
                    }
                    return nextEvent
                }
            }
        }

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

    private func isScrollOrTextInput(_ view: NSView?) -> Bool {
        var currentView = view
        while let view = currentView {
            if view is FocusedTextField.InputScrollView || view is NSTextView {
                return true
            }
            if view.enclosingScrollView is FocusedTextField.InputScrollView {
                return true
            }
            if view is NSScrollView {
                return true
            }
            currentView = view.superview
        }
        return false
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
    @State private var query = ""
    @State private var selectedTaskID: TaskSessionRecord.ID?
    @State private var hoveredTaskID: TaskSessionRecord.ID?
    @State private var hoverSelectionEnabled = false
    @State private var textWidth: CGFloat = FocusedTextField.minWidth
    @State private var textHeight: CGFloat = 20
    @State private var inputRowHeight: CGFloat = Self.fallbackInputRowHeight
    @State private var bottomBarHeight: CGFloat = Self.fallbackBottomBarHeight


    private var sortedTasks: [TaskSessionRecord] {
        appDelegate.taskRecords.sorted { lhs, rhs in
            if lhs.lastActivityAt == rhs.lastActivityAt {
                return lhs.startedAt > rhs.startedAt
            }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
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

    var body: some View {
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
        .frame(width: Self.panelWidth)
        .reportHeight(CommandMenuTaskListContentHeightPreferenceKey.self)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .onPreferenceChange(CommandMenuTaskListContentHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            appDelegate.updateCommandMenuSize(CGSize(width: Self.panelWidth, height: height))
        }
    }

    private var taskListContent: some View {
        VStack(spacing: 0) {
            inputRow

            Divider()

            if hasVisibleList {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(sortedTasks) { task in
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
                    .onChange(of: selectedTaskID) { _, newID in
                        guard let newID else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
                .frame(maxHeight: maxTaskSectionHeight)

                Divider()
            }

            bottomBar
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
        }
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)

            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text("Start a new task from your Home folder...")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }

                FocusedTextField(
                    text: $query,
                    textWidth: $textWidth,
                    textHeight: $textHeight,
                    onSubmit: submitInput,
                    onKeyDown: handleInputKeyDown,
                    font: .systemFont(ofSize: 17, weight: .regular)
                )
                .frame(height: max(textHeight, 22))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            VoiceTrailingIndicator(
                state: appDelegate.commandMenuVoiceState,
                level: appDelegate.commandMenuVoiceLevel
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
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
        selectedTaskID = sortedTasks.first?.id
    }

    private func moveTaskSelection(by delta: Int) {
        guard !sortedTasks.isEmpty else { return }
        guard let currentSelectionID = selectedTaskID,
              let currentIndex = sortedTasks.firstIndex(where: { $0.id == currentSelectionID }) else {
            selectFirstTaskIfNeeded()
            return
        }

        let nextIndex = min(max(currentIndex + delta, 0), sortedTasks.count - 1)
        selectedTaskID = sortedTasks[nextIndex].id
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

                TaskRuntimeStatusView(task: task)
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

struct TaskRuntimeStatusView: View {
    @ObservedObject var task: TaskSessionRecord
    @State private var pulse = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let running = task.isRunning
            let endTime = running ? timeline.date : (task.completedAt ?? timeline.date)

            HStack(spacing: 7) {
                Image(systemName: "circle.grid.2x2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(running ? Color.green : Color.secondary)
                    .opacity(running && pulse ? 0.45 : 0.95)

                Text(formattedElapsed(endTime.timeIntervalSince(task.startedAt)))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(running ? Color.green : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill((running ? Color.green : Color.black).opacity(running ? 0.12 : 0.06))
            )
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func formattedElapsed(_ elapsed: TimeInterval) -> String {
        let totalSeconds = max(Int(elapsed.rounded(.down)), 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }

        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        }

        return "\(seconds)s"
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

            PanelInputRow(
                viewModel: viewModel,
                textWidth: $chatTextWidth,
                textHeight: $chatTextHeight,
                expandsTextField: true
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

            TaskRuntimeStatusView(task: task)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var chatTranscript: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(viewModel.chatHistory.enumerated()), id: \.offset) { _, entry in
                if entry.role == "user" {
                    Text("> \(entry.text)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    EventsSummaryView(events: entry.events, isDone: true)
                    AssistantMarkdown(text: entry.text)
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

        let quitItem = NSMenuItem(title: "Quit HyperPointer", action: #selector(MenuActionHandler.performAction(_:)), keyEquivalent: "q")
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

private struct CommandMenuTaskListContentHeightPreferenceKey: PreferenceKey {
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
