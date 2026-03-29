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
