import AppKit
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
    private static let estimatedTaskRowHeight: CGFloat = 46

    @ObservedObject var appDelegate: AppDelegate
    @State private var query = ""
    @State private var selectedTaskID: TaskSessionRecord.ID?
    @State private var textWidth: CGFloat = FocusedTextField.minWidth
    @State private var textHeight: CGFloat = 20
    @State private var inputRowHeight: CGFloat = Self.fallbackInputRowHeight
    @State private var bottomBarHeight: CGFloat = Self.fallbackBottomBarHeight
    @State private var measuredTaskListContentHeight: CGFloat = 0

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
        guard queryIsEmpty else {
            return [
                CommandMenuShortcutItem(label: "Run", keys: ["↩"])
            ]
        }

        guard let selectedTask else { return [] }

        var shortcuts = [
            CommandMenuShortcutItem(label: "Open", keys: ["↩"])
        ]

        if selectedTask.isRunning {
            shortcuts.append(CommandMenuShortcutItem(label: "Stop", keys: ["⌫"]))
        }

        shortcuts.append(CommandMenuShortcutItem(label: "Delete", keys: ["⌘", "⌫"]))
        return shortcuts
    }

    private var hasTasks: Bool {
        !sortedTasks.isEmpty
    }

    private var dividerCount: CGFloat {
        hasTasks ? 2 : 1
    }

    private var estimatedTaskListHeight: CGFloat {
        guard hasTasks else { return 0 }
        return CGFloat(sortedTasks.count) * Self.estimatedTaskRowHeight + (Self.taskListVerticalPadding * 2)
    }

    private var taskListContentHeight: CGFloat {
        measuredTaskListContentHeight > 0 ? measuredTaskListContentHeight : estimatedTaskListHeight
    }

    private var chromeHeight: CGFloat {
        inputRowHeight + bottomBarHeight + (dividerCount * Self.dividerHeight)
    }

    private var maxTaskSectionHeight: CGFloat {
        max(Self.maxPanelHeight - chromeHeight, 0)
    }

    private var taskSectionHeight: CGFloat {
        guard hasTasks else { return 0 }
        return min(taskListContentHeight, maxTaskSectionHeight)
    }

    private var panelHeight: CGFloat {
        chromeHeight + taskSectionHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            inputRow

            Divider()

            if hasTasks {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(sortedTasks) { task in
                                CommandMenuTaskRow(
                                    task: task,
                                    isSelected: task.id == selectedTaskID,
                                    onSelect: { selectedTaskID = task.id },
                                    onOpen: { open(task) }
                                )
                                .id(task.id)
                            }
                        }
                        .padding(.vertical, Self.taskListVerticalPadding)
                        .reportHeight(CommandMenuTaskListContentHeightPreferenceKey.self)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: taskSectionHeight)
                    .onPreferenceChange(CommandMenuTaskListContentHeightPreferenceKey.self) { height in
                        guard height > 0 else { return }
                        measuredTaskListContentHeight = height
                    }
                    .onChange(of: selectedTaskID) { _, selectedTaskID in
                        guard let selectedTaskID else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(selectedTaskID, anchor: .center)
                        }
                    }
                }

                Divider()
            }

            bottomBar
        }
        .frame(width: Self.panelWidth, height: panelHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .onAppear {
            selectFirstTaskIfNeeded()
            syncPanelSize()
        }
        .onChange(of: sortedTasks.map(\.id)) { _, _ in
            if let selectedTaskID,
               sortedTasks.contains(where: { $0.id == selectedTaskID }) {
                return
            }
            selectFirstTaskIfNeeded()
        }
        .onChange(of: panelHeight) { _, _ in
            syncPanelSize()
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
            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.04))
                    )
            }
            .buttonStyle(.plain)

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
            return
        }

        appDelegate.launchTaskFromCommandMenu(query: trimmedQuery)
        query = ""
        appDelegate.closeCommandMenu()
    }

    private func handleInputKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 125:
            moveSelection(by: 1)
            return true
        case 126:
            moveSelection(by: -1)
            return true
        case 36, 76:
            if queryIsEmpty {
                openSelectedTask()
                return true
            }
        case 51:
            if modifiers.contains(.command), queryIsEmpty {
                deleteSelectedTask()
                return true
            }

            if modifiers.isEmpty, queryIsEmpty {
                stopSelectedTask()
                return true
            }
        case 43:
            if modifiers.contains(.command) {
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

    private func moveSelection(by delta: Int) {
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
        appDelegate.closeCommandMenu()
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

    private func syncPanelSize() {
        appDelegate.updateCommandMenuSize(CGSize(width: Self.panelWidth, height: panelHeight))
    }
}

private struct CommandMenuTaskRow: View {
    @ObservedObject var task: TaskSessionRecord
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

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
                    .fill(isSelected ? Color.black.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .onHover { isHovering in
            if isHovering {
                onSelect()
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

private struct TaskRuntimeStatusView: View {
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
