# Regression Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a two-layer regression testing system (Swift tests + checklist) plus a `/regression` slash command for capturing new regressions.

**Architecture:** Extract testable pure logic from `SearchViewModel` and `SearchView` into a `ThisCore` library target. Add a `ThisTests` test target with Swift Testing. Create `REGRESSIONS.md` as an AI-readable checklist. Create a `/regression` Claude Code custom command.

**Tech Stack:** Swift Testing framework, Swift Package Manager, Claude Code custom commands (.claude/commands/)

---

### Task 1: Create ThisCore Library Target with Extracted Types

**Files:**
- Create: `Sources/ThisCore/AccessibilityTypes.swift`
- Create: `Sources/ThisCore/AccessibilityHelpers.swift`
- Modify: `Package.swift`

- [ ] **Step 1: Create the ThisCore directory**

```bash
mkdir -p Sources/ThisCore
```

- [ ] **Step 2: Create `Sources/ThisCore/AccessibilityTypes.swift`**

This defines the protocol for testable accessibility element logic, the role sets, and constants.

```swift
import Foundation

// MARK: - Testable element protocol

/// Protocol abstracting AXUIElement so tests can use mock elements.
public protocol UIElementNode {
    var role: String? { get }
    var title: String? { get }
    var elementDescription: String? { get }
    var value: String? { get }
    var selectedText: String? { get }
    var children: [any UIElementNode] { get }
}

// MARK: - Role sets

/// Interactive/item-level roles — use as primary element.
public let primaryRoles: Set<String> = [
    "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox",
    "AXRadioButton", "AXSlider", "AXPopUpButton", "AXComboBox",
    "AXMenuItem", "AXMenuBarItem", "AXTab", "AXCell", "AXRow",
    "AXHeading", "AXDockItem", "AXDisclosureTriangle",
    "AXColorWell", "AXIncrementor",
    "AXStaticText", "AXImage"
]

/// Container roles — good as ancestor context but too broad as primary.
public let containerRoles: Set<String> = [
    "AXList", "AXTable", "AXOutline", "AXToolbar", "AXTabGroup",
    "AXScrollArea", "AXSplitGroup", "AXGroup"
]

/// Threshold for stale accessibility tree detection.
public let staleThreshold = 3
```

- [ ] **Step 3: Create `Sources/ThisCore/AccessibilityHelpers.swift`**

Extract pure functions from SearchViewModel.

```swift
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
```

- [ ] **Step 4: Update `Package.swift` to add ThisCore library and ThisTests test target**

Replace the entire file:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "This",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "ThisCore",
            path: "Sources/ThisCore"
        ),
        .executableTarget(
            name: "This",
            dependencies: [
                "ThisCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            exclude: ["Info.plist", "ThisCore"],
            resources: [
                .process("Resources/A4.wav"),
                .process("Resources/C5.wav"),
                .copy("Resources/AppIcon.icns"),
                .process("Resources/StatusBarIcon.png"),
                .process("Resources/StatusBarIcon@2x.png"),
                .process("Resources/StatusBarIcon@3x.png"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Info.plist",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .testTarget(
            name: "ThisTests",
            dependencies: ["ThisCore"],
            path: "Tests/ThisTests"
        ),
    ]
)
```

- [ ] **Step 5: Verify the package resolves**

Run: `cd /Users/jasonmarsh/conductor/workspaces/hyper-pointer/munich-v2 && swift package resolve`
Expected: resolves without errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/ThisCore/ Package.swift
git commit -m "feat: add ThisCore library with extracted accessibility types and helpers"
```

---

### Task 2: Wire SearchViewModel to Use ThisCore

**Files:**
- Modify: `Sources/SearchViewModel.swift`

The goal is to make `SearchViewModel` use the role sets and constants from `ThisCore` while keeping the `AXUIElement`-dependent logic in place. The private copies in `SearchViewModel` become references to the public ones in `ThisCore`.

- [ ] **Step 1: Add import and replace role sets**

At the top of `Sources/SearchViewModel.swift`, add:

```swift
import ThisCore
```

Then remove the following private declarations (they now come from ThisCore):

- Lines 441-448: `private let primaryRoles: Set<String> = [...]` — delete entirely
- Lines 450-454: `private let containerRoles: Set<String> = [...]` — delete entirely
- Lines 43: `private let staleThreshold = 3` — delete entirely

The `meaningfulRoles` set (lines 456-467) stays — it's only used in `SearchViewModel` and combines both sets.

- [ ] **Step 2: Build to verify**

Run: `cd /Users/jasonmarsh/conductor/workspaces/hyper-pointer/munich-v2 && swift build 2>&1 | tail -5`
Expected: Build succeeds. The public `primaryRoles`, `containerRoles`, and `staleThreshold` from ThisCore are now used.

- [ ] **Step 3: Commit**

```bash
git add Sources/SearchViewModel.swift
git commit -m "refactor: use ThisCore role sets and constants in SearchViewModel"
```

---

### Task 3: Write Regression Tests

**Files:**
- Create: `Tests/ThisTests/CoordinateConversionTests.swift`
- Create: `Tests/ThisTests/ElectronGroupTests.swift`
- Create: `Tests/ThisTests/RoleSetTests.swift`
- Create: `Tests/ThisTests/MockElement.swift`

- [ ] **Step 1: Create test directory**

```bash
mkdir -p Tests/ThisTests
```

- [ ] **Step 2: Create `Tests/ThisTests/MockElement.swift`**

```swift
import ThisCore

struct MockElement: UIElementNode {
    var role: String?
    var title: String?
    var elementDescription: String?
    var value: String?
    var selectedText: String?
    var children: [any UIElementNode]

    init(
        role: String? = nil,
        title: String? = nil,
        elementDescription: String? = nil,
        value: String? = nil,
        selectedText: String? = nil,
        children: [any UIElementNode] = []
    ) {
        self.role = role
        self.title = title
        self.elementDescription = elementDescription
        self.value = value
        self.selectedText = selectedText
        self.children = children
    }
}
```

- [ ] **Step 3: Create `Tests/ThisTests/CoordinateConversionTests.swift`**

```swift
import Testing
import CoreGraphics
@testable import ThisCore

@Suite("Coordinate Conversion")
struct CoordinateConversionTests {

    @Test func flipsYAxisForContainingScreen() {
        let points = accessibilityQueryPoints(
            mouseLocation: CGPoint(x: 500, y: 300),
            screenFrames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        )
        #expect(points.contains { $0.x == 500 && $0.y == 780 })
    }

    @Test func includesOriginalCoordinate() {
        let points = accessibilityQueryPoints(
            mouseLocation: CGPoint(x: 500, y: 300),
            screenFrames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        )
        #expect(points.contains { $0.x == 500 && $0.y == 300 })
    }

    @Test func generatesMultiplePoints() {
        let points = accessibilityQueryPoints(
            mouseLocation: CGPoint(x: 500, y: 300),
            screenFrames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        )
        #expect(points.count >= 2)
    }

    @Test func handlesMultipleScreens() {
        let screens = [
            CGRect(x: 0, y: 0, width: 1920, height: 1080),
            CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        ]
        let points = accessibilityQueryPoints(
            mouseLocation: CGPoint(x: 2000, y: 500),
            screenFrames: screens
        )
        // Should flip Y relative to the screen containing the point (second screen)
        #expect(points.contains { $0.x == 2000 && $0.y == 940 }) // 1440 - 500
    }

    @Test func deduplicatesIdenticalPoints() {
        let points = accessibilityQueryPoints(
            mouseLocation: CGPoint(x: 500, y: 300),
            screenFrames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
        )
        let uniqueCount = Set(points.map { "\($0.x),\($0.y)" }).count
        #expect(points.count == uniqueCount)
    }
}
```

- [ ] **Step 4: Create `Tests/ThisTests/RoleSetTests.swift`**

```swift
import Testing
@testable import ThisCore

@Suite("Role Sets")
struct RoleSetTests {

    @Test func containerRolesIncludesAXGroup() {
        #expect(containerRoles.contains("AXGroup"))
    }

    @Test func containerRolesIncludesAXScrollArea() {
        #expect(containerRoles.contains("AXScrollArea"))
    }

    @Test func containerRolesIncludesAXSplitGroup() {
        #expect(containerRoles.contains("AXSplitGroup"))
    }

    @Test func primaryRolesIncludesAXButton() {
        #expect(primaryRoles.contains("AXButton"))
    }

    @Test func primaryRolesIncludesAXStaticText() {
        #expect(primaryRoles.contains("AXStaticText"))
    }

    @Test func primaryRolesDoesNotIncludeAXGroup() {
        #expect(!primaryRoles.contains("AXGroup"))
    }

    @Test func staleThresholdIsThree() {
        #expect(staleThreshold == 3)
    }
}
```

- [ ] **Step 5: Create `Tests/ThisTests/ElectronGroupTests.swift`**

```swift
import Testing
@testable import ThisCore

@Suite("Electron App Group Drilling")
struct ElectronGroupTests {

    @Test func findsBestChildInSingleLevelGroup() {
        let root = MockElement(role: "AXGroup", children: [
            MockElement(role: "AXButton", title: "Save")
        ])
        let result = findBestChild(in: root)
        #expect(result?.role == "AXButton")
        #expect(result?.title == "Save")
    }

    @Test func drillsTwoLevelsDeep() {
        let root = MockElement(role: "AXGroup", children: [
            MockElement(role: "AXGroup", children: [
                MockElement(role: "AXTextField", value: "hello")
            ])
        ])
        let result = findBestChild(in: root)
        #expect(result?.role == "AXTextField")
    }

    @Test func drillsThreeLevelsDeep() {
        let root = MockElement(role: "AXGroup", children: [
            MockElement(role: "AXGroup", children: [
                MockElement(role: "AXGroup", children: [
                    MockElement(role: "AXButton", title: "OK")
                ])
            ])
        ])
        let result = findBestChild(in: root)
        #expect(result?.role == "AXButton")
    }

    @Test func stopsAtMaxDepth() {
        // 4 levels deep — should NOT find the button at depth 3 when maxDepth is 3
        let root = MockElement(role: "AXGroup", children: [
            MockElement(role: "AXGroup", children: [
                MockElement(role: "AXGroup", children: [
                    MockElement(role: "AXGroup", children: [
                        MockElement(role: "AXButton", title: "Hidden")
                    ])
                ])
            ])
        ])
        let result = findBestChild(in: root, maxDepth: 3)
        #expect(result == nil)
    }

    @Test func prefersPrimaryRoleOverMeaningfulContent() {
        let root = MockElement(role: "AXGroup", children: [
            MockElement(role: "AXButton", title: "Click me"),
            MockElement(role: "AXGroup", title: "Has a title")
        ])
        let result = findBestChild(in: root)
        #expect(result?.role == "AXButton")
    }

    @Test func fallsBackToMeaningfulContent() {
        let root = MockElement(role: "AXGroup", children: [
            MockElement(role: "AXGroup"),
            MockElement(role: "AXGroup", title: "Important label")
        ])
        let result = findBestChild(in: root)
        #expect(result?.title == "Important label")
    }

    @Test func returnsNilForEmptyContainer() {
        let root = MockElement(role: "AXGroup", children: [])
        let result = findBestChild(in: root)
        #expect(result == nil)
    }

    @Test func returnsNilForNestedEmptyContainers() {
        let root = MockElement(role: "AXGroup", children: [
            MockElement(role: "AXGroup", children: [
                MockElement(role: "AXGroup", children: [])
            ])
        ])
        let result = findBestChild(in: root)
        #expect(result == nil)
    }

    @Test func hasMeaningfulContentWithTitle() {
        let node = MockElement(title: "Hello")
        #expect(hasMeaningfulContent(node) == true)
    }

    @Test func hasMeaningfulContentWithValue() {
        let node = MockElement(value: "typed text")
        #expect(hasMeaningfulContent(node) == true)
    }

    @Test func hasMeaningfulContentEmpty() {
        let node = MockElement()
        #expect(hasMeaningfulContent(node) == false)
    }

    @Test func scansUpToTwentyChildren() {
        // 25 children: first 20 are empty groups, 21st is a button
        // Should NOT find the button (past the prefix(20) limit)
        var children: [any UIElementNode] = (0..<20).map { _ in
            MockElement(role: "AXGroup") as any UIElementNode
        }
        children.append(MockElement(role: "AXButton", title: "Hidden"))
        let root = MockElement(role: "AXGroup", children: children)
        let result = findBestChild(in: root)
        #expect(result == nil)
    }
}
```

- [ ] **Step 6: Run the tests to verify they fail (no implementation wired yet if build issues) or pass**

Run: `cd /Users/jasonmarsh/conductor/workspaces/hyper-pointer/munich-v2 && swift test 2>&1 | tail -20`
Expected: All tests pass (since ThisCore already has the implementation).

- [ ] **Step 7: Commit**

```bash
git add Tests/
git commit -m "test: add regression tests for coordinate conversion, role sets, and group drilling"
```

---

### Task 4: Create REGRESSIONS.md

**Files:**
- Create: `REGRESSIONS.md`

- [ ] **Step 1: Create `REGRESSIONS.md` at repo root**

```markdown
# Regression Checklist

Behaviors below have regressed before. Each MUST hold true before merging any PR.
**Never remove entries from this file.** Only append.

---

## 1. Desktop Detection

**Correct:** When the cursor is over the desktop (no app windows at that point), the app detects it and returns a desktop hover snapshot.

**Where:** `Sources/SearchViewModel.swift`

**Assertions:**
- `isDesktopRegion(at:)` method exists and uses `CGWindowListCopyWindowInfo` with `.optionOnScreenOnly` and `.excludeDesktopElements`
- `desktopHoverSnapshot(at:)` method exists and calls `isDesktopRegion`
- In `updateHoveredApp()`, when `copyElementAtMouseLocation` returns nil, `desktopHoverSnapshot` is called as fallback
- `accessibilityQueryPoints(for:)` converts coordinates using `screen.frame.maxY - mouseLocation.y`

**Broken state:** Desktop not detected; hovering over desktop shows nothing or clears state.

---

## 2. Floating Panel Default Icon

**Correct:** The minimal indicator shows the app's own icon (`NSApp.applicationIconImage`) when no hovered context icon is available.

**Where:** `Sources/SearchView.swift` — `minimalIndicator` view

**Assertions:**
- The `else` branch in `minimalIndicator` uses `Image(nsImage: NSApp.applicationIconImage)`, NOT `Image(systemName: "command")`
- `ContextSummaryView.leadingIcon` also uses `NSApp.applicationIconImage` as its fallback

**Broken state:** The ⌘ symbol appears instead of the app icon.

---

## 3. Electron App Group Handling

**Correct:** When an Electron app reports UI elements primarily as AXGroup, the app drills into children to find meaningful elements.

**Where:** `Sources/SearchViewModel.swift` and `Sources/ThisCore/AccessibilityTypes.swift`

**Assertions:**
- `containerRoles` set includes `"AXGroup"` (tested in Swift test suite)
- `findBestChild(in:)` drills at least 3 levels deep (tested in Swift test suite)
- `findBestChild` scans up to 20 children per level (tested in Swift test suite)
- `resolveElement` calls `findBestChild` when the leaf element has a container role
- Stale tree detection resets after `staleThreshold` (3) consecutive container results

**Broken state:** Electron apps like VS Code or Slack only show "Group" with no useful element info.

---

## 4. Coordinate Conversion

**Correct:** Accessibility query points include a Y-flipped coordinate per screen (NSEvent bottom-left → Accessibility top-left).

**Where:** `Sources/ThisCore/AccessibilityHelpers.swift` (extracted) and `Sources/SearchViewModel.swift` (calls it)

**Assertions:**
- Tested in Swift test suite: `accessibilityQueryPoints` flips Y axis correctly
- Multiple points generated (per-screen, global desktop, original)
- Points are deduplicated

**Broken state:** Desktop detection or element lookup fails on certain screen configurations.
```

- [ ] **Step 2: Commit**

```bash
git add REGRESSIONS.md
git commit -m "docs: add REGRESSIONS.md checklist for AI-enforced regression verification"
```

---

### Task 5: Create `/regression` Slash Command

**Files:**
- Create: `.claude/commands/regression.md`

Claude Code custom commands live in `.claude/commands/` as markdown files. The filename becomes the slash command name.

- [ ] **Step 1: Create the commands directory**

```bash
mkdir -p .claude/commands
```

- [ ] **Step 2: Create `.claude/commands/regression.md`**

```markdown
A regression has been discovered. Your job is to document it so it never happens again.

## Instructions

1. Ask the user: "What regressed? Describe the broken behavior in one sentence."
   - If the user already described it in the message, skip this step.

2. Search the codebase to find the relevant code. Identify:
   - Which file(s) and function(s) are involved
   - What the correct behavior looks like in the current code
   - What the broken state would look like

3. Append a new entry to `REGRESSIONS.md`. Use this format:

```
---

## N. [Short Title]

**Correct:** [What should happen]

**Where:** [File path] — [function/view name]

**Assertions:**
- [Specific code assertion 1]
- [Specific code assertion 2]

**Broken state:** [What happens when this regresses]
```

   - Increment the entry number from the last entry in the file.
   - **NEVER remove or modify existing entries.**

4. If the regression involves pure logic that can be tested without system APIs (macOS Accessibility, CGWindowList, SwiftUI views), also add a Swift test:
   - Add the test to the appropriate file in `Tests/ThisTests/`
   - If needed, extract logic into `Sources/ThisCore/` first
   - The test must fail when the regression is present and pass when the code is correct

5. Run `swift test` to verify all tests pass.

6. Commit with message: `guard: add regression check for [short description]`
```

- [ ] **Step 3: Commit**

```bash
git add .claude/
git commit -m "feat: add /regression slash command for capturing new regressions"
```

---

### Task 6: Create CLAUDE.md

**Files:**
- Create: `CLAUDE.md`

- [ ] **Step 1: Create `CLAUDE.md` at repo root**

```markdown
# This — AI Coding Guidelines

## Build & Test

```
swift build          # Build the app
swift test           # Run regression tests (MUST pass before completing any task)
make run             # Build, sign, and run
```

## Regression Tracking

This project uses `REGRESSIONS.md` to track behaviors that have regressed before.

- **Before completing any task:** run `swift test`
- **When fixing a bug:** check if it should be added to `REGRESSIONS.md` — use `/regression` to add an entry
- **Never remove entries** from `REGRESSIONS.md`
- **Never modify existing tests** in `Tests/ThisTests/` without flagging to the user — these guard against known regressions

## Project Structure

- `Sources/` — main app code (SwiftUI, macOS)
- `Sources/ThisCore/` — extracted pure logic (testable without system APIs)
- `Tests/ThisTests/` — regression test suite
- `REGRESSIONS.md` — human + AI readable regression checklist
- `.claude/commands/regression.md` — `/regression` slash command
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add CLAUDE.md with build, test, and regression tracking guidelines"
```

---

### Task 7: Add `make test` Target and Verify Everything Works

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Add test target to Makefile**

Add after the `build` target (after line 13):

```makefile
test:
	swift test
```

Also add `test` to the `.PHONY` line (line 7).

- [ ] **Step 2: Run the full test suite**

Run: `cd /Users/jasonmarsh/conductor/workspaces/hyper-pointer/munich-v2 && make test 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 3: Run a full build to verify the app still compiles**

Run: `cd /Users/jasonmarsh/conductor/workspaces/hyper-pointer/munich-v2 && swift build 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "feat: add make test target for running regression tests"
```

---

### Task 8: Update SearchViewModel to Use Extracted accessibilityQueryPoints

**Files:**
- Modify: `Sources/SearchViewModel.swift`

The `accessibilityQueryPoints(for:)` method in SearchViewModel currently has its own implementation. Replace it with a call to the ThisCore version.

- [ ] **Step 1: Replace the private method**

Replace the existing `accessibilityQueryPoints(for:)` method (lines 949-967) with a wrapper that calls the ThisCore function:

```swift
private func accessibilityQueryPoints(for mouseLocation: CGPoint) -> [CGPoint] {
    let screenFrames = NSScreen.screens.map { $0.frame }
    return ThisCore.accessibilityQueryPoints(mouseLocation: mouseLocation, screenFrames: screenFrames)
}
```

- [ ] **Step 2: Build and test**

Run: `cd /Users/jasonmarsh/conductor/workspaces/hyper-pointer/munich-v2 && swift build 2>&1 | tail -5 && swift test 2>&1 | tail -10`
Expected: Build succeeds, all tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/SearchViewModel.swift
git commit -m "refactor: delegate coordinate conversion to ThisCore"
```
