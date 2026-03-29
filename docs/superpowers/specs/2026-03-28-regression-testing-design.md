# Regression Testing Design

## Problem

AI coding agents silently revert previous fixes across PRs. Specific regressions that have occurred multiple times:

1. **Desktop detection breaks** — `isDesktopRegion(at:)` in SearchViewModel gets removed or altered. Has cycled through commits `23430dd` → `37e9e8a` → `1740c96`.
2. **Floating panel shows ⌘ instead of app icon** — `minimalIndicator` in SearchView.swift falls back to `Image(systemName: "command")` instead of `NSApp.applicationIconImage`.
3. **Electron app group drilling regresses** — `findBestChild` in SearchViewModel stops drilling into `AXGroup` children. Fixed in `e5d9717`, deepened in `23430dd`, reverted in `37e9e8a`, re-fixed in `1740c96`.

## Solution: Two-Layer Regression Testing

### Layer 1: Swift Test Suite (Mechanically Enforced)

A `swift test` target that catches regressions automatically.

#### Package Structure Changes

Add two new targets to `Package.swift`:

- **`ThisCore`** — a library target containing extracted pure logic from the main app. Both the `This` executable and tests depend on it.
- **`ThisTests`** — a test target using Swift Testing framework, depends on `ThisCore`.

```
Sources/
  ThisCore/
    AccessibilityHelpers.swift   — coordinate conversion, container roles, drilling logic
    IconResolution.swift         — icon fallback logic
  (existing files stay in Sources/)
Tests/
  ThisTests/
    DesktopDetectionTests.swift
    IconFallbackTests.swift
    ElectronGroupTests.swift
    CoordinateConversionTests.swift
```

#### What Gets Extracted into `ThisCore`

**From SearchViewModel.swift:**

1. `accessibilityQueryPoints(for:on:)` — pure coordinate math converting NSEvent coordinates to Accessibility API coordinates. Currently lines 949-967.
2. `containerRoles` — the `Set<String>` defining which roles are containers. Currently lines 450-454.
3. `staleThreshold` — the constant (currently 3) for stale tree detection.
4. `findBestChild` drilling logic — extracted to work on a `UIElementProtocol` instead of raw `AXUIElement`, allowing mock elements in tests.
5. `resolveElement` core logic — the decision tree for when to drill vs. walk up.

**From SearchView.swift:**

6. `defaultPanelIcon()` — a function that returns `NSApp.applicationIconImage`, used by `minimalIndicator` as its fallback. Testable assertion: this function must NOT return nil and must NOT be the system "command" symbol.

#### UIElementProtocol

To test accessibility drilling without real `AXUIElement`:

```swift
public protocol UIElementProtocol {
    var role: String? { get }
    var title: String? { get }
    var descriptionValue: String? { get }
    var value: String? { get }
    var children: [any UIElementProtocol] { get }
}
```

Real `AXUIElement` gets a conformance wrapper. Tests use `MockElement`.

#### Key Tests

```swift
// DesktopDetectionTests.swift
@Test func coordinateConversionFlipsYAxis() {
    let points = accessibilityQueryPoints(
        mouseLocation: CGPoint(x: 500, y: 300),
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
    )
    #expect(points.contains { $0.y == 780 }) // 1080 - 300
}

@Test func multipleQueryPointsGenerated() {
    let points = accessibilityQueryPoints(
        mouseLocation: CGPoint(x: 500, y: 300),
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080)
    )
    #expect(points.count >= 2) // multiple coordinate versions
}

// ElectronGroupTests.swift
@Test func containerRolesIncludesAXGroup() {
    #expect(containerRoles.contains("AXGroup"))
}

@Test func findBestChildDrillsThreeLevels() {
    let root = MockElement(role: "AXGroup", children: [
        MockElement(role: "AXGroup", children: [
            MockElement(role: "AXGroup", children: [
                MockElement(role: "AXButton", title: "Save")
            ])
        ])
    ])
    let result = findBestChild(in: root, maxDepth: 3)
    #expect(result?.role == "AXButton")
}

@Test func findBestChildPrefersNamedElements() {
    let root = MockElement(role: "AXGroup", children: [
        MockElement(role: "AXGroup"),
        MockElement(role: "AXButton", title: "OK")
    ])
    let result = findBestChild(in: root)
    #expect(result?.title == "OK")
}

@Test func staleThresholdIsThree() {
    #expect(staleThreshold == 3)
}

// IconFallbackTests.swift
@Test func defaultPanelIconIsAppIcon() {
    let icon = defaultPanelIcon()
    #expect(icon != nil)
    // Verify it's the app icon, not a system symbol
    #expect(icon === NSApp.applicationIconImage)
}
```

### Layer 2: Regression Checklist (AI-Enforced)

A `REGRESSIONS.md` file at the repo root. Contains specific, verifiable assertions about code that has regressed before. Used by:

- **Conductor code review preferences** — review agent must verify each item
- **Conductor general preferences** — all agents are aware of the checklist
- **Human review** — quick visual scan before merge

#### Contents

Each entry includes:
- What the behavior is
- Where the code lives (file + function name)
- What the correct state looks like
- What the broken state looks like

See the `REGRESSIONS.md` file itself for full contents.

### Layer 3: `/regression` Skill (Discovery Workflow)

A custom Claude Code skill invoked via `/regression` that captures newly discovered regressions. When the user finds a regression and types `/regression`, the skill:

1. **Asks what regressed** — short description of the broken behavior
2. **Finds the relevant code** — searches the codebase to locate the fix/expected behavior
3. **Appends to `REGRESSIONS.md`** — adds a new entry with:
   - What the correct behavior is
   - What file/function it lives in
   - What the broken state looks like
   - Never removes or modifies existing entries
4. **Adds a Swift test** if the behavior is testable as pure logic (extracts into `ThisCore` if needed)
5. **Commits both** with a message like "Add regression guard: [description]"

This is the primary way `REGRESSIONS.md` grows over time. The user discovers a problem, invokes the skill, and the system captures it permanently.

### Conductor Integration

**Run script:**
```
swift test
```

**Code review preferences (addition):**
```
Before approving any PR, you MUST verify every item in REGRESSIONS.md.
For each entry:
1. Read the actual source file and function listed
2. Confirm the "correct state" matches what's in the code
3. Confirm the "broken state" is NOT present
Do not rely on the diff alone — regressions often happen in code that
wasn't part of the PR's intended changes. If any item is violated,
flag it as a blocking issue and do not approve.
```

**General preferences (addition):**
```
This project has regression tests (swift test) and a REGRESSIONS.md
checklist. Before completing any task, run swift test. Do not modify
code in ways that break existing tests. If you need to change behavior
covered by a test, update the test to match — but flag this to the user.
```

**CLAUDE.md (addition):**
```
## Regression tracking
This project uses REGRESSIONS.md to track behaviors that have regressed before.
Run `swift test` before completing any task.
When fixing a bug, check if it should be added to REGRESSIONS.md — invoke
/regression or manually add an entry.
```

## Non-Goals

- CI/GitHub Actions integration (tests run locally only)
- UI snapshot testing (SwiftUI views are covered by checklist, not test suite)
- Full accessibility API mocking (we test extracted logic, not system API calls)
- Performance testing
- Code coverage targets

## Future Extensions

As new regressions are discovered:
1. Add a test to `ThisTests` if the behavior can be extracted into pure logic
2. Add an entry to `REGRESSIONS.md` either way
3. Both layers grow organically over time
