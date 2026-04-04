# This

`This` is a cursor-aware macOS assistant. It lets you point at something on screen, hold a key, and turn that object into the start of a task.

The current app is no longer just a small floating chat bubble. It now has three working surfaces:

- a cursor-following panel for object-first tasks
- a global command menu for launching and revisiting work
- persistent task icons and chats for long-running jobs

Under the hood, `This` reads UI context from macOS Accessibility APIs, captures screenshots when needed, tries fast deterministic actions locally, and falls back to Claude CLI when the task needs full agent behavior.

## Why It Exists

Most AI desktop tools still make you restate context the computer can already see.

`This` starts from what you are already looking at:

- the app under your pointer
- the specific UI element under your pointer
- selected text
- file and folder context when available
- the current browser URL when available
- a screenshot of the relevant screen or window

That makes the prompt shorter and the control surface tighter. You point first, then ask.

## What The App Does Now

### 1. Cursor panel

Hold your configured invoke key and a small panel appears next to your pointer. It tracks the object under the cursor, can show a live highlight around the detected element, and can anchor in place when you release the key so you can type.

### 2. Voice-first invocation

If Auto-voice is enabled, voice capture starts as soon as you hold the invoke key. If Auto-voice is off, hold `Shift` while invoking to speak instead of typing. The dictated transcript is submitted directly into the same task flow.

### 3. Global command menu

Press your invoke key plus `Space` to open a full command menu. It acts as a launcher, task inbox, and task switcher for ongoing chats. You can pin it, keep multiple tasks alive, and reopen work without hunting for the original floating panel.

### 4. Fast local actions before Claude

For simple requests, `This` does not always need to launch Claude first. It can route certain commands through a fast local path, including:

- open, focus, hide, or quit an app
- focus, minimize, maximize, or close a window
- open, reveal, or copy the path of a hovered file or folder

If the request is ambiguous, multi-step, or needs reasoning, it falls back to Claude with the full captured context.

### 5. Persistent tasks and task icons

Long-running tasks can collapse into a minimal task icon that follows the source window. You can reopen the full chat from the command menu, keep multiple tasks running, and preserve history across task views.

### 6. Visual feedback

The app can show:

- object detection highlight overlays
- object text inside the panel
- a ghost cursor that mirrors the agent's attention while a task is running
- optional click sounds and debug labels for ghost cursor behavior

### 7. Guided onboarding and settings

The current onboarding flow walks through:

- Claude CLI setup
- Accessibility
- Screen Recording
- optional Microphone
- optional Speech Recognition
- optional Reminders
- optional Input Monitoring

Settings now expose invoke key choice, sound effects, Auto-voice, Claude defaults, quick actions, structured UI rendering, object overlays, and ghost cursor controls.

## How It Works

1. Hold your invoke key over something on screen.
2. `This` inspects the object under your cursor using Accessibility APIs and related system context.
3. Keep holding to speak, or release to anchor the panel and type.
4. The app decides whether the request can be handled as a fast local action.
5. If not, it packages your prompt with the captured context and hands the task to Claude CLI.
6. The response streams into a compact chat UI, and long tasks can continue as persistent task sessions.

## Ways To Launch It

- Hold the invoke key to open the cursor panel.
- Press invoke key + `Space` to open the command menu.
- Double right-click, or right-click and hold, to open a context panel at the pointer.
- Use the menu bar item to open the command menu, onboarding, settings, update checks, or feedback.

The invoke key is configurable. The app currently supports `Fn`, `Control`, `Option`, or `Command`, with `Control` as the stored default when no preference has been set yet.

## Permissions

| Permission | Why the app uses it |
|---|---|
| Accessibility | Inspect the UI under your pointer, detect windows and focused elements, and perform certain local UI actions |
| Screen Recording | Capture the current screen or window for screenshot context |
| Microphone | Record dictated prompts while invoking |
| Speech Recognition | Transcribe spoken prompts on-device through macOS services |
| Reminders | Read or create reminders when a task calls for it |
| Input Monitoring | Observe modifier and input events outside the app when needed |

Some Claude-driven workflows may also trigger separate macOS consent prompts later, depending on which apps or system services a task tries to control.

## Requirements

- macOS 14.0+
- [Claude CLI](https://github.com/anthropics/claude-code) installed on the Mac you want to use with `This`

## Install The Latest Release

```bash
curl -fsSL https://raw.githubusercontent.com/jasPreMar/this/main/scripts/install.sh | bash
```

That downloads the latest DMG from GitHub Releases, installs `This.app`, opens it, and starts onboarding.

If `/Applications` is not writable, the installer falls back to `~/Applications`.

## Build From Source

```bash
git clone https://github.com/jasPreMar/this.git
cd this
make build
```

Run regression tests:

```bash
make test
```

Run a signed debug app bundle so macOS permission behavior matches the packaged app more closely:

```bash
make run
```

Build a standard app bundle:

```bash
make app
open dist/This.app
```

Install the app bundle:

```bash
make install
```

Build a drag-to-install DMG:

```bash
make dmg
open dist/This.dmg
```

## First-Run Setup

On first launch, `This` opens onboarding so you can:

- verify or install Claude CLI
- choose an invoke key
- grant required permissions
- test the interaction model before using it in real apps

If you are testing permission behavior locally, prefer launching the packaged app bundle rather than the raw executable.

## Developer Notes

### TCC grants for local testing

If you want to skip the macOS permission dialogs during local development:

```bash
sudo make grant
```

This writes grants directly into the user TCC database for the app bundle identifier used by local builds.

To clear them again:

```bash
make reset-tcc
```

### Signing, notarization, and release packaging

The build scripts prefer the best available signing identity in your keychain and fall back to ad-hoc signing when needed. For distribution outside your machine, use a real `Developer ID Application` identity and notarize the result.

Build a Developer ID signed app:

```bash
./scripts/build-app.sh \
  --sign-mode developer-id \
  --sign-identity "Developer ID Application: Your Name (TEAMID)"
```

Notarize the app:

```bash
./scripts/notarize.sh \
  --path dist/This.app \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

Build and notarize the DMG:

```bash
./scripts/build-dmg.sh \
  --skip-build \
  --app-path dist/This.app \
  --sign-mode developer-id \
  --sign-identity "Developer ID Application: Your Name (TEAMID)"

./scripts/notarize.sh \
  --path dist/This.dmg \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

For deeper release notes, see `MACOS_GATEKEEPER_NOTARIZATION_CHECKLIST.md`.

### Sparkle release signing

The release workflow signs the published DMG with Sparkle's Ed25519 key. It expects a `SPARKLE_PRIVATE_KEY` repository secret containing the exported private key contents.

Generate a keypair:

```bash
swift package resolve
./.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

Export the private key for CI:

```bash
./.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
```

Copy the contents of `sparkle-private-key.txt` into the `SPARKLE_PRIVATE_KEY` GitHub secret, then delete the file.

## Source Map

| File | Responsibility |
|---|---|
| `Sources/AppDelegate.swift` | App lifecycle, menu bar UI, hotkeys, command menu, task persistence, overlays |
| `Sources/FloatingPanel.swift` | Cursor panel behavior, task icon mode, voice handoff, and pre-Claude routing |
| `Sources/SearchViewModel.swift` | Hovered object detection, context assembly, screenshot capture, and prompt bootstrapping |
| `Sources/CommandMenu.swift` | Global command menu UI and task switching |
| `Sources/QuickActionCoordinator.swift` | Decides whether a request can run locally before Claude |
| `Sources/LocalCommandExecutor.swift` | Executes supported app, window, and file quick actions |
| `Sources/TerminalContentView.swift` | Claude process management, streaming chat UI, and structured responses |
| `Sources/OnboardingView.swift` | First-run setup flow and tutorial |
| `Sources/SettingsView.swift` | User preferences for invocation, chat, overlays, and permissions |
| `Sources/GhostCursor*.swift` | Synthetic cursor feedback for running tasks |
| `Sources/HighlightOverlay*.swift` | Element highlight overlays around detected UI objects |

## Things To Try

- Hold the invoke key over a browser tab and ask for a summary of the current page.
- Hover a file or folder in Finder and ask to reveal it, open it, or copy its path.
- Open the command menu and launch a task without switching away from your current app.
- Enable the ghost cursor and watch how task attention is visualized during longer runs.
- Turn on Structured UI and compare rich responses against plain markdown replies.
