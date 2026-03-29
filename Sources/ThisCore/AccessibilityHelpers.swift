import Foundation
import CoreGraphics

// MARK: - Coordinate conversion

/// Converts NSEvent mouse coordinates to accessibility API query points.
/// NSEvent uses bottom-left origin; accessibility API uses top-left origin per screen.
public func accessibilityQueryPoints(
    mouseLocation: CGPoint,
    screenFrames: [CGRect]
) -> [CGPoint] {
    var points: [CGPoint] = []

    // Per-screen coordinate conversion
    if let screen = screenFrames.first(where: { $0.contains(mouseLocation) }) {
        points.append(CGPoint(x: mouseLocation.x, y: screen.maxY - mouseLocation.y))
    }

    // Global desktop coordinate conversion
    let desktopFrame = screenFrames.reduce(CGRect.null) { $0.union($1) }
    points.append(CGPoint(x: mouseLocation.x, y: desktopFrame.maxY - mouseLocation.y))

    // Original coordinate
    points.append(mouseLocation)

    // Deduplicate
    var unique: [CGPoint] = []
    for point in points where !unique.contains(point) {
        unique.append(point)
    }
    return unique
}

// MARK: - Element drilling

/// Whether a node has meaningful text content (title, description, value, or selected text).
public func hasMeaningfulContent(_ node: any UIElementNode) -> Bool {
    let title = node.title ?? ""
    let desc = node.elementDescription ?? ""
    let val = node.value ?? ""
    let sel = node.selectedText ?? ""
    return !title.isEmpty || !desc.isEmpty || !val.isEmpty || !sel.isEmpty
}

/// Search children of a container for a more specific primary-role element.
/// Caps recursion at `maxDepth` levels (default 3) to avoid performance issues.
public func findBestChild(
    in container: any UIElementNode,
    depth: Int = 0,
    maxDepth: Int = 3
) -> (any UIElementNode)? {
    guard depth < maxDepth else { return nil }
    let children = container.children
    guard !children.isEmpty else { return nil }

    // First pass: direct child with a primary role
    for child in children.prefix(20) {
        if let role = child.role, primaryRoles.contains(role) {
            return child
        }
    }

    // Second pass: child with meaningful content
    for child in children.prefix(20) where hasMeaningfulContent(child) {
        return child
    }

    // Third pass: recurse into container children
    for child in children.prefix(20) {
        if let role = child.role, containerRoles.contains(role) {
            if let found = findBestChild(in: child, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
    }

    return nil
}
