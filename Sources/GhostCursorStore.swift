import AppKit
import Combine
import Foundation

final class GhostCursorStore: ObservableObject {
    @Published private(set) var renderStates: [GhostCursorRenderState] = []

    private var actors: [UUID: GhostCursorActor] = [:]
    private var pendingLaunches: [UUID: String] = [:]
    private var timer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private let playClickSound: () -> Void

    init(playClickSound: @escaping () -> Void = {}) {
        self.playClickSound = playClickSound
        startDisplayTimer()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.tick(now: Date())
        }
    }

    deinit {
        timer?.invalidate()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    func registerTask(_ taskId: UUID, anchorPoint: CGPoint?) {
        if let actor = actors[taskId] {
            actor.register(anchorPoint: anchorPoint)
        } else {
            actors[taskId] = GhostCursorActor(taskId: taskId, anchorPoint: anchorPoint)
        }
    }

    func unregisterTask(_ taskId: UUID) {
        actors.removeValue(forKey: taskId)
        pendingLaunches.removeValue(forKey: taskId)
        renderStates.removeAll { $0.id == taskId }
    }

    func emit(activity: GhostCursorActivity) {
        registerTask(activity.taskId, anchorPoint: activity.screenPoint)
        let now = activity.timestamp.timeIntervalSinceReferenceDate
        actors[activity.taskId]?.apply(activity: activity, now: now)
        tick(now: activity.timestamp)
    }

    func setTaskVisible(_ taskId: UUID, visible: Bool) {
        actors[taskId]?.setVisible(visible)
        if !visible {
            pendingLaunches.removeValue(forKey: taskId)
        }
        tick(now: Date())
    }

    func trackPendingLaunch(taskId: UUID, appName: String?) {
        guard let appName, !appName.isEmpty else {
            pendingLaunches.removeValue(forKey: taskId)
            return
        }
        pendingLaunches[taskId] = normalizedAppName(appName)
    }

    func handleActivatedApplication(_ application: NSRunningApplication, windowFrame: CGRect?) {
        guard !pendingLaunches.isEmpty else { return }

        let applicationName = normalizedAppName(application.localizedName)
        let matchingTaskId = pendingLaunches.first(where: { $0.value == applicationName })?.key
            ?? pendingLaunches.keys.first

        guard let taskId = matchingTaskId else { return }

        let activity = GhostCursorActivity(
            taskId: taskId,
            timestamp: Date(),
            kind: .focusWindow,
            label: application.localizedName.map { "\($0) ready" } ?? "App ready",
            screenPoint: windowFrame?.center,
            confidence: windowFrame == nil ? .coarse : .inferred
        )
        pendingLaunches.removeValue(forKey: taskId)
        emit(activity: activity)
    }

    func tick(now: Date = Date()) {
        guard AppSettings.ghostCursorEnabled else {
            renderStates = []
            return
        }

        let time = now.timeIntervalSinceReferenceDate
        var nextStates: [GhostCursorRenderState] = []

        for actor in actors.values {
            let update = actor.update(now: time)
            if update.shouldPlayClickSound && AppSettings.ghostCursorClickSoundEnabled {
                playClickSound()
            }
            if let renderState = update.renderState {
                nextStates.append(renderState)
            }
        }

        renderStates = nextStates.sorted { lhs, rhs in
            lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func renderStates(for screenFrame: CGRect) -> [GhostCursorRenderState] {
        let expandedFrame = screenFrame.insetBy(dx: -48, dy: -48)
        return renderStates.filter { expandedFrame.contains($0.point) }
    }

    private func startDisplayTimer() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick(now: Date())
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func normalizedAppName(_ appName: String?) -> String {
        appName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }
}
