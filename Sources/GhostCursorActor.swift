import AppKit
import Foundation

struct GhostCursorRenderState: Identifiable, Equatable {
    let id: UUID
    let point: CGPoint
    let scale: CGFloat
    let pulseRadius: CGFloat
    let pulseOpacity: CGFloat
    let label: String?
    let confidence: GhostCursorConfidence
}

final class GhostCursorActor {
    private enum Phase {
        case hidden
        case idling
        case moving(Move)
        case clicking(Click)
    }

    private struct Move {
        let startPoint: CGPoint
        let endPoint: CGPoint
        let startTime: TimeInterval
        let duration: TimeInterval
        let clickAfterArrival: Bool
    }

    private struct Click {
        let startTime: TimeInterval
    }

    let taskId: UUID

    private var phase: Phase = .hidden
    private var anchorPoint: CGPoint
    private var renderedPoint: CGPoint
    private var hasAnchorPoint = false
    private var isVisible = false
    private var label: String?
    private var confidence: GhostCursorConfidence = .coarse
    private var lastClickSoundAt: TimeInterval = -.infinity
    private var lastUpdateTime: TimeInterval?
    private var idleDrift: CGPoint = .zero
    private let idleSeedX: Double
    private let idleSeedY: Double

    init(taskId: UUID, anchorPoint: CGPoint?) {
        self.taskId = taskId
        let initialPoint = anchorPoint ?? .zero
        self.anchorPoint = initialPoint
        self.renderedPoint = initialPoint
        self.hasAnchorPoint = anchorPoint != nil

        let hash = taskId.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        self.idleSeedX = Double(hash % 17) * 0.37
        self.idleSeedY = Double(hash % 29) * 0.21
    }

    func register(anchorPoint: CGPoint?) {
        guard let anchorPoint else { return }

        if !hasAnchorPoint {
            self.anchorPoint = anchorPoint
            renderedPoint = anchorPoint
            hasAnchorPoint = true
            if isVisible {
                phase = .idling
            }
            return
        }

        if !isVisible {
            self.anchorPoint = anchorPoint
            renderedPoint = anchorPoint
        }
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if !visible {
            phase = .hidden
            idleDrift = .zero
        } else if hasAnchorPoint, case .hidden = phase {
            phase = .idling
        }
    }

    func apply(activity: GhostCursorActivity, now: TimeInterval) {
        label = activity.label
        confidence = activity.confidence

        guard isVisible else { return }

        guard let screenPoint = activity.screenPoint else {
            if case .hidden = phase, hasAnchorPoint {
                phase = .idling
            } else if hasAnchorPoint {
                phase = .idling
            }
            return
        }

        if !hasAnchorPoint {
            anchorPoint = screenPoint
            renderedPoint = screenPoint
            hasAnchorPoint = true
        }

        let distance = renderedPoint.distance(to: screenPoint)
        let duration = moveDuration(for: distance)

        anchorPoint = screenPoint
        idleDrift = .zero

        if distance < 1.5 {
            renderedPoint = screenPoint
            if activity.kind.requiresClickFeedback {
                phase = .clicking(Click(startTime: now))
            } else {
                phase = .idling
            }
            return
        }

        phase = .moving(
            Move(
                startPoint: renderedPoint,
                endPoint: screenPoint,
                startTime: now,
                duration: duration,
                clickAfterArrival: activity.kind.requiresClickFeedback
            )
        )
    }

    func update(now: TimeInterval) -> (renderState: GhostCursorRenderState?, shouldPlayClickSound: Bool) {
        let deltaTime = frameDelta(now: now)
        defer { lastUpdateTime = now }

        guard isVisible, hasAnchorPoint else {
            phase = .hidden
            return (nil, false)
        }

        var scale: CGFloat = 1
        var pulseRadius: CGFloat = 8
        var pulseOpacity: CGFloat = 0
        var shouldPlayClickSound = false

        switch phase {
        case .hidden:
            phase = .idling
            renderedPoint = anchorPoint
            idleDrift = .zero

        case .idling:
            idleDrift = nextIdleDrift(now: now, deltaTime: deltaTime)
            renderedPoint = anchorPoint + idleDrift

        case .moving(let move):
            let rawProgress = min(max((now - move.startTime) / move.duration, 0), 1)
            let easedProgress = easedMoveProgress(rawProgress)
            renderedPoint = .lerp(from: move.startPoint, to: move.endPoint, progress: easedProgress)

            if rawProgress >= 1 {
                renderedPoint = move.endPoint
                anchorPoint = move.endPoint
                if move.clickAfterArrival {
                    phase = .clicking(Click(startTime: now))
                    shouldPlayClickSound = consumeClickSoundAllowance(at: now)
                } else {
                    idleDrift = .zero
                    phase = .idling
                }
            }

        case .clicking(let click):
            renderedPoint = anchorPoint
            let rawProgress = min(max((now - click.startTime) / 0.24, 0), 1)

            if rawProgress < 0.32 {
                let local = CGFloat(rawProgress / 0.32)
                scale = 1 - (1 - 0.92) * local
            } else if rawProgress < 0.58 {
                let local = CGFloat((rawProgress - 0.32) / 0.26)
                scale = 0.92 + (1.03 - 0.92) * local
            } else {
                let local = CGFloat((rawProgress - 0.58) / 0.42)
                scale = 1.03 + (1 - 1.03) * min(max(local, 0), 1)
            }

            pulseRadius = 8 + CGFloat(easedPulseProgress(rawProgress)) * 20
            pulseOpacity = CGFloat(1 - rawProgress) * 0.32

            if rawProgress >= 1 {
                phase = .idling
                scale = 1
                pulseOpacity = 0
                idleDrift = .zero
                renderedPoint = anchorPoint
            }
        }

        let renderState = GhostCursorRenderState(
            id: taskId,
            point: renderedPoint,
            scale: scale,
            pulseRadius: pulseRadius,
            pulseOpacity: pulseOpacity,
            label: label,
            confidence: confidence
        )
        return (renderState, shouldPlayClickSound)
    }

    private func consumeClickSoundAllowance(at now: TimeInterval) -> Bool {
        guard now - lastClickSoundAt >= 0.12 else { return false }
        lastClickSoundAt = now
        return true
    }

    private func moveDuration(for distance: CGFloat) -> TimeInterval {
        let normalized = min(max(Double(distance / 720), 0), 1)
        return 0.18 + normalized * 0.24
    }

    private func easedMoveProgress(_ progress: Double) -> CGFloat {
        if progress < 0.5 {
            return CGFloat(4 * progress * progress * progress)
        }
        let adjusted = -2 * progress + 2
        return CGFloat(1 - (adjusted * adjusted * adjusted) / 2)
    }

    private func easedPulseProgress(_ progress: Double) -> Double {
        1 - pow(1 - progress, 2.6)
    }

    private func idleOffset(at now: TimeInterval) -> CGPoint {
        let x = sin(now * 0.82 + idleSeedX) * 3.2
        let y = cos(now * 1.07 + idleSeedY) * 2.4
        return CGPoint(x: x, y: y)
    }

    private func nextIdleDrift(now: TimeInterval, deltaTime: TimeInterval) -> CGPoint {
        let target = idleOffset(at: now)
        let response = CGFloat(1 - exp(-deltaTime * 3.8))
        return .lerp(from: idleDrift, to: target, progress: response)
    }

    private func frameDelta(now: TimeInterval) -> TimeInterval {
        guard let lastUpdateTime else { return 1.0 / 60.0 }
        return min(max(now - lastUpdateTime, 1.0 / 240.0), 1.0 / 20.0)
    }
}
