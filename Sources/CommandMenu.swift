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
    @ObservedObject var appDelegate: AppDelegate
    @State private var query = ""
    @State private var selectedTaskID: TaskSessionRecord.ID?
    @State private var textWidth: CGFloat = FocusedTextField.minWidth
    @State private var textHeight: CGFloat = 20

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

    var body: some View {
        VStack(spacing: 0) {
            inputRow

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if sortedTasks.isEmpty {
                            emptyState
                        } else {
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
                    }
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: selectedTaskID) { _, selectedTaskID in
                    guard let selectedTaskID else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(selectedTaskID, anchor: .center)
                    }
                }
            }

            Divider()

            bottomBar
        }
        .frame(width: 720, height: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .onAppear {
            selectFirstTaskIfNeeded()
        }
        .onChange(of: sortedTasks.map(\.id)) { _, _ in
            if let selectedTaskID,
               sortedTasks.contains(where: { $0.id == selectedTaskID }) {
                return
            }
            selectFirstTaskIfNeeded()
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
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 10) {
            Spacer(minLength: 40)
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No tasks yet")
                .font(.system(size: 15, weight: .semibold))
            Text("Run a task from the field above and it will stay here until you delete it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
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

            CommandMenuShortcut(label: "Open", keys: ["↩"], isEnabled: selectedTask != nil)
            CommandMenuShortcut(label: "Stop", keys: ["⌫"], isEnabled: selectedTask?.isRunning == true)
            CommandMenuShortcut(label: "Delete", keys: ["⌘", "⌫"], isEnabled: selectedTask != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.035))
    }

    private func submitInput() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            openSelectedTask()
            return
        }

        appDelegate.launchTaskFromCommandMenu(query: trimmed)
        query = ""
        appDelegate.closeCommandMenu()
    }

    private func handleInputKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let queryIsEmpty = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

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
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)

            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.6))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(isEnabled ? 0.08 : 0.04))
                        )
                }
            }
        }
    }
}
