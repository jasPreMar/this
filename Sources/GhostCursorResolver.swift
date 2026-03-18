import AppKit
import Foundation

struct GhostCursorResolutionContext {
    let panelFrame: CGRect?
    let hoveredElementFrame: CGRect?
    let hoveredWindowFrame: CGRect?
    let hoveredScreenPoint: CGPoint?
    let hoveredParts: [String]
    let workingDirectoryURL: URL?
}

enum GhostCursorResolver {
    static func resolve(
        taskId: UUID,
        intent: GhostCursorIntent,
        context: GhostCursorResolutionContext,
        now: Date = Date()
    ) -> GhostCursorActivity {
        switch intent {
        case .click(let label):
            if let elementFrame = context.hoveredElementFrame {
                return GhostCursorActivity(
                    taskId: taskId,
                    timestamp: now,
                    kind: .click,
                    label: label ?? fallbackHoverLabel(from: context),
                    screenPoint: elementFrame.center,
                    confidence: .exact
                )
            }

            if let hoveredPoint = context.hoveredScreenPoint {
                return GhostCursorActivity(
                    taskId: taskId,
                    timestamp: now,
                    kind: .click,
                    label: label ?? fallbackHoverLabel(from: context),
                    screenPoint: hoveredPoint,
                    confidence: .inferred
                )
            }

            return GhostCursorActivity(
                taskId: taskId,
                timestamp: now,
                kind: .click,
                label: label ?? "Clicking",
                screenPoint: nil,
                confidence: .coarse
            )

        case .appLaunch(let appName):
            return GhostCursorActivity(
                taskId: taskId,
                timestamp: now,
                kind: .appLaunch,
                label: "Launching \(appName)",
                screenPoint: neutralLaunchPoint(for: context),
                confidence: .coarse
            )

        case .pathSearch(let label, let path, let query):
            let searchLabel: String
            if let label, !label.isEmpty {
                searchLabel = label
            } else if let query, !query.isEmpty {
                searchLabel = "Searching for \(query)"
            } else if let path, !path.isEmpty {
                searchLabel = "Searching \(URL(fileURLWithPath: path).lastPathComponent)"
            } else if let workingDirectoryURL = context.workingDirectoryURL {
                searchLabel = "Searching \(workingDirectoryURL.lastPathComponent)"
            } else {
                searchLabel = "Searching"
            }

            return GhostCursorActivity(
                taskId: taskId,
                timestamp: now,
                kind: .pathSearch,
                label: searchLabel,
                screenPoint: anchorPoint(for: context),
                confidence: .coarse
            )

        case .focusWindow(let label):
            if let windowFrame = context.hoveredWindowFrame {
                return GhostCursorActivity(
                    taskId: taskId,
                    timestamp: now,
                    kind: .focusWindow,
                    label: label ?? "Focusing window",
                    screenPoint: windowFrame.center,
                    confidence: .inferred
                )
            }

            return GhostCursorActivity(
                taskId: taskId,
                timestamp: now,
                kind: .focusWindow,
                label: label ?? "Focusing window",
                screenPoint: anchorPoint(for: context),
                confidence: .coarse
            )

        case .genericWork(let label):
            return GhostCursorActivity(
                taskId: taskId,
                timestamp: now,
                kind: .genericWork,
                label: label ?? "Working",
                screenPoint: anchorPoint(for: context),
                confidence: .coarse
            )
        }
    }

    private static func anchorPoint(for context: GhostCursorResolutionContext) -> CGPoint? {
        if let hoveredScreenPoint = context.hoveredScreenPoint {
            return hoveredScreenPoint
        }
        if let panelFrame = context.panelFrame {
            return panelFrame.center
        }
        return nil
    }

    private static func neutralLaunchPoint(for context: GhostCursorResolutionContext) -> CGPoint? {
        let anchor = anchorPoint(for: context)
        guard let screen = screen(containing: anchor) else { return anchor }

        let visibleFrame = screen.visibleFrame
        return CGPoint(
            x: visibleFrame.midX,
            y: visibleFrame.minY + min(92, visibleFrame.height * 0.12)
        )
    }

    private static func screen(containing point: CGPoint?) -> NSScreen? {
        guard let point else { return NSScreen.main }
        return NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
    }

    private static func fallbackHoverLabel(from context: GhostCursorResolutionContext) -> String? {
        guard let lastPart = context.hoveredParts.last, !lastPart.isEmpty else { return nil }
        if let colonRange = lastPart.range(of: ": ") {
            return "Clicking \(lastPart[colonRange.upperBound...])"
        }
        return "Clicking \(lastPart)"
    }
}
