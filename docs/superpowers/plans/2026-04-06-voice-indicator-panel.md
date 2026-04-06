# Voice Indicator Panel — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the voice waveform out of the floating cursor panel into a separate bottom-center panel, with compact (hovering) and expanded (pinned/persistent) modes.

**Architecture:** Create a new `VoiceIndicatorPanel` (NSPanel subclass) that displays at the bottom-center of the screen. FloatingPanel owns it and shows/hides it based on voice state. The floating cursor panel keeps only object detection content (app icon, object text). The voice panel has two visual modes: compact (just waveform, during cursor-follow) and expanded (cancel + waveform + send buttons, during pinned-follow mode).

**Tech Stack:** SwiftUI, AppKit (NSPanel), existing PanelChrome component

---

### Task 1: Create VoiceIndicatorPanel

**Files:**
- Create: `Sources/VoiceIndicatorPanel.swift`

- [ ] **Step 1: Create the SwiftUI view for the voice indicator**

```swift
import SwiftUI

struct VoiceIndicatorContentView: View {
    let voiceLevel: CGFloat
    let isPinnedMode: Bool
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        PanelChrome(cornerRadius: 16, usesNativeGlassSurface: NativeGlass.isSupported) {
            HStack(spacing: 8) {
                if isPinnedMode {
                    Button(action: onCancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                CompactVoiceWaveformView(level: voiceLevel)

                if isPinnedMode {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.accentColor))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
```

- [ ] **Step 2: Create the NSPanel subclass**

```swift
class VoiceIndicatorPanel: NSPanel {
    private var hostingView: NSHostingView<VoiceIndicatorContentView>!
    private var voiceLevel: CGFloat = 0
    private var isPinnedMode: Bool = false
    private var onCancel: () -> Void = {}
    private var onSend: () -> Void = {}

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        rebuildHostingView()
    }

    func update(voiceLevel: CGFloat, isPinnedMode: Bool, onCancel: @escaping () -> Void, onSend: @escaping () -> Void) {
        self.voiceLevel = voiceLevel
        self.isPinnedMode = isPinnedMode
        self.onCancel = onCancel
        self.onSend = onSend
        rebuildHostingView()
        positionAtBottomCenter()
    }

    func showPanel() {
        positionAtBottomCenter()
        orderFront(nil)
    }

    func hidePanel() {
        orderOut(nil)
    }

    private func rebuildHostingView() {
        let content = VoiceIndicatorContentView(
            voiceLevel: voiceLevel,
            isPinnedMode: isPinnedMode,
            onCancel: onCancel,
            onSend: onSend
        )
        if hostingView == nil {
            hostingView = NSHostingView(rootView: content)
            contentView = hostingView
        } else {
            hostingView.rootView = content
        }
        hostingView.invalidateIntrinsicContentSize()
    }

    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let fittingSize = hostingView.fittingSize
        setContentSize(fittingSize)
        let x = screen.visibleFrame.midX - fittingSize.width / 2
        let y = screen.visibleFrame.minY + 20
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
```

- [ ] **Step 3: Verify it builds**

Run: `swift build`
Expected: Build succeeds (panel not yet wired up)

- [ ] **Step 4: Commit**

```bash
git add Sources/VoiceIndicatorPanel.swift
git commit -m "feat: add VoiceIndicatorPanel for bottom-center voice display"
```

---

### Task 2: Remove voice waveform from the floating cursor panel

**Files:**
- Modify: `Sources/SearchView.swift`

- [ ] **Step 1: Remove VoiceTrailingIndicator from ContextSummaryView**

In `ContextSummaryView.body`, remove the `VoiceTrailingIndicator` and the `Spacer` before it. The HStack becomes:

```swift
    var body: some View {
        HStack(spacing: 7) {
            leadingIcon
                .frame(width: 16, height: 16, alignment: .center)

            Text(displayText(text))
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovered = $0 }
    }
```

Also remove the `voiceState` and `voiceLevel` properties from `ContextSummaryView` and its init.

- [ ] **Step 2: Remove VoiceTrailingIndicator from PanelInputRow**

In `PanelInputRow.body`, remove the `VoiceTrailingIndicator(...)` line and its `.padding(.top, 1)`.

- [ ] **Step 3: Remove VoiceTrailingIndicator from compact icon row in PanelHeaderSection**

In the `else if viewModel.hoveredContextIcon != nil` block, remove the `VoiceTrailingIndicator` line.

- [ ] **Step 4: Remove the standalone voice-mode row from PanelHeaderSection**

Remove the entire block:
```swift
if viewModel.isVoiceModeActive, (!viewModel.objectTextEnabled || viewModel.hoveredParts.last == nil), viewModel.hoveredContextIcon == nil {
    HStack(spacing: 8) {
        ...
    }
}
```

- [ ] **Step 5: Update ContextSummaryView call site in PanelHeaderSection**

Remove `voiceState:` and `voiceLevel:` arguments from the `ContextSummaryView(...)` initializer call in PanelHeaderSection.

- [ ] **Step 6: Update fullPanelWidth for command key mode**

Since the waveform is no longer in the floating panel, the compact width when objectTextEnabled is off should be just the icon. Update `fullPanelWidth`:

```swift
private var fullPanelWidth: CGFloat {
    if viewModel.isCommandKeyMode {
        return !viewModel.objectTextEnabled ? 44 : 168
    }
    return 320
}
```

(16px icon + 10px padding each side + a bit of breathing room = ~44px)

- [ ] **Step 7: Update hasPanelHeaderContent**

Remove `isVoiceModeActive` from the condition since voice is no longer shown in the header:

```swift
var hasPanelHeaderContent: Bool {
    !selectedText.isEmpty || hoveredContextIcon != nil || (objectTextEnabled && hoveredParts.last != nil)
}
```

- [ ] **Step 8: Verify it builds**

Run: `swift build`
Expected: Build succeeds

- [ ] **Step 9: Commit**

```bash
git add Sources/SearchView.swift
git commit -m "refactor: remove voice waveform from floating cursor panel"
```

---

### Task 3: Wire VoiceIndicatorPanel into FloatingPanel

**Files:**
- Modify: `Sources/FloatingPanel.swift`

- [ ] **Step 1: Add the voiceIndicatorPanel property**

Add near the other panel properties (around line 38):

```swift
private lazy var voiceIndicatorPanel = VoiceIndicatorPanel()
```

- [ ] **Step 2: Show/hide voice indicator in handleVoiceStateChange**

In `handleVoiceStateChange(_:)`, after updating `searchViewModel.voiceState`, show or hide the voice indicator panel:

```swift
private func handleVoiceStateChange(_ state: VoiceDictationController.State) {
    switch state {
    case .idle:
        searchViewModel.voiceState = .idle
        searchViewModel.voiceLevel = 0
        voiceIndicatorPanel.hidePanel()
        if !isCommandKeyHeld {
            scheduleRealtimeLogStopIfNeeded()
        }
    case .listening:
        cancelPendingRealtimeLogStop()
        searchViewModel.voiceState = .listening
        showVoiceIndicator()
    case .transcribing:
        cancelPendingRealtimeLogStop()
        searchViewModel.voiceState = .transcribing
        searchViewModel.voiceLevel = 0
        // Keep voice indicator visible during transcription
    case .failed(let message):
        searchViewModel.voiceState = .failed(message)
        searchViewModel.voiceLevel = 0
        voiceIndicatorPanel.hidePanel()
        if !isCommandKeyHeld {
            RealtimeInputLog.shared.stopSession()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.searchViewModel.voiceState == .failed(message) else { return }
            self.searchViewModel.voiceState = .idle
        }
    }
}
```

- [ ] **Step 3: Add showVoiceIndicator helper**

```swift
private func showVoiceIndicator() {
    let isPinned = invokeHoldBehavior == .pinnedFollow
    voiceIndicatorPanel.update(
        voiceLevel: searchViewModel.voiceLevel,
        isPinnedMode: isPinned,
        onCancel: { [weak self] in
            self?.voiceController.cancel()
            self?.dismiss(restorePreviousFocus: true)
        },
        onSend: { [weak self] in
            self?.voiceController.stop()
        }
    )
    voiceIndicatorPanel.showPanel()
}
```

- [ ] **Step 4: Update voice level changes to forward to voice indicator**

In the `voiceController.onLevelChange` callback (around line 241), add:

```swift
voiceController.onLevelChange = { [weak self] level in
    self?.searchViewModel.voiceLevel = level
    if self?.searchViewModel.voiceState == .listening {
        self?.showVoiceIndicator()
    }
}
```

- [ ] **Step 5: Hide voice indicator on dismiss**

In `dismiss(restorePreviousFocus:)` (line ~1827), add:

```swift
func dismiss(restorePreviousFocus: Bool = true) {
    voiceIndicatorPanel.hidePanel()
    shouldRestoreFocusOnClose = restorePreviousFocus
    close()
}
```

Also in `hidePersistentTaskWindow(restorePreviousFocus:)` add `voiceIndicatorPanel.hidePanel()` before the `orderOut(nil)` call.

- [ ] **Step 6: Verify it builds**

Run: `swift build`
Expected: Build succeeds

- [ ] **Step 7: Run regression tests**

Run: `swift run ThisTests`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add Sources/FloatingPanel.swift
git commit -m "feat: wire VoiceIndicatorPanel to show at bottom-center during voice input"
```

---

### Task 4: Clean up unused voice properties

**Files:**
- Modify: `Sources/SearchView.swift`

- [ ] **Step 1: Remove unused VoiceTrailingIndicator and voice params**

If `VoiceTrailingIndicator` is no longer referenced anywhere in SearchView.swift, it can stay as a shared component (it's still used by VoiceIndicatorPanel indirectly via `CompactVoiceWaveformView`). Check for any remaining references to voice state/level in SearchView that are now unused.

The `voiceState` and `voiceLevel` properties on `ContextSummaryView` should already be removed in Task 2. Verify no compiler warnings about unused variables.

- [ ] **Step 2: Verify full build and tests**

Run: `swift build && swift run ThisTests`
Expected: Build succeeds, all tests pass

- [ ] **Step 3: Commit**

```bash
git add Sources/SearchView.swift
git commit -m "chore: clean up unused voice references in SearchView"
```
