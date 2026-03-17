# HyperPointer

We have a new kind of computer. It can write code, browse the web, manage files, send emails, and control applications. It's genuinely powerful. But right now, it lives in the command line. You open a chat window, start from a blank page, and describe what you want. Every time. The AI is capable, but it's blind — it doesn't know what's on your screen, what you're looking at, or what you're trying to act on. You have to explain the context yourself before you can give the command.

The interface is a bottleneck.

One fix is to start with objects instead of words. Your screen is full of them right now — apps, windows, icons, folders, buttons, text fields, images, links. These are the things you're actually trying to act on. If you could point at any one of them and issue a command — open this, rename that, summarize this, rewrite that, delete this, copy that, move this — you'd be giving the AI something it's currently missing: a target. A specific thing to work on, with full context already attached.

This isn't a new idea — it's actually the original idea behind the graphical user interface. When the first GUIs were designed, they were solving a similar problem. The command line was powerful but required you to know the exact syntax for every operation. The GUI made computing accessible by introducing four things: windows, icons, menus, and a pointer. The pointer let you aim at objects directly. The icons made those objects visible and recognizable. The menus revealed what you could do with them.

That model held up for decades. But menus were always a workaround — a fixed list of options decided in advance by whoever built the software. You were limited to commands they anticipated.

With AI, that limitation disappears. You're no longer choosing from a list. You can ask for anything, in plain language, and the system figures out how to do it. So the windows, icons, and pointer are still useful — the spatial, visual model of computing is still the best way to understand what's on your screen. But the menu is the part that can go. Replace it with a command. Replace the fixed list with a conversation. Keep the pointer, keep the objects, and let the AI handle the rest.

## How it works

Normally, using an AI assistant goes like this:

1. See something on screen
2. Switch to a chat window
3. Type: *"I'm in VS Code, looking at a red error in the Problems panel that says 'Cannot find module'..."*
4. Ask your question

You spend half your effort just describing the context before you can even ask the question.

HyperPointer removes that step:

1. **Press `Ctrl+Space`** (or hold `⌘` and move your mouse, or `Cmd+right-click`)
2. **A floating panel appears** next to your cursor, above every other window
3. **The app reads what's under your cursor** using macOS's Accessibility API — the same system screen readers use. It sees the app name, the UI element you're hovering (e.g. `button: Submit` or `text: Cannot find module`), any selected text, and the current URL if you're in a browser
4. **It takes a screenshot** of the window you're looking at
5. **You type your question and hit Enter** — your question, the context, and the screenshot are all sent to Claude automatically
6. **Claude responds in the panel**, streaming as it arrives. Follow-up messages keep the full conversation context
7. **Close the panel** and focus returns to exactly where you were

## How it's built

| File | What it does |
|---|---|
| `AppDelegate.swift` | Boots the app; listens globally for `Ctrl+Space` and `⌘+right-click` |
| `FloatingPanel.swift` | The floating window — lives above all other windows, follows your cursor |
| `SearchViewModel.swift` | Reads the Accessibility tree to identify what's under the cursor; takes screenshots |
| `TerminalContentView.swift` | The chat UI that streams Claude's response |
| `ClaudeProcessManager` | Shells out to the `claude` CLI to talk to Claude |

## Permissions

| Permission | Why |
|---|---|
| Accessibility | To read what UI element is under your cursor |
| Screen Recording | To take a screenshot of the window you're looking at |
| Automation | So Claude can run `osascript` to control other apps when you ask it to |

## Requirements

- macOS 14.0+ (Sonoma)
- [Claude CLI](https://github.com/anthropics/claude-code) installed
- Accessibility and Screen Recording permissions granted to the app

## Setup

To install the latest released build from the terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/jasPreMar/hyper-pointer/main/scripts/install.sh | bash
```

That downloads the latest DMG from GitHub Releases, installs `HyperPointer.app`, opens it, and launches the onboarding wizard.

To build from source:

```bash
git clone https://github.com/jasPreMar/hyper-pointer.git
cd hyper-pointer
make build
./.build/debug/HyperPointer
```

To package it as a normal macOS app bundle:

```bash
make app
open dist/HyperPointer.app
```

To install the app into `/Applications`:

```bash
make install
```

If your shell user cannot write to `/Applications`, rerun with `sudo` or choose a different destination:

```bash
sudo make install
INSTALL_DIR="$HOME/Applications" make install
```

To build a drag-to-install disk image:

```bash
make dmg
open dist/HyperPointer.dmg
```

On first launch, HyperPointer opens an onboarding wizard that walks through:

- Installing or verifying Claude CLI
- Accessibility
- Screen Recording
- Optional microphone and speech permissions for invoke-key dictation
- Optional Automation approvals for the apps you want HyperPointer to control

You can reopen the wizard any time from the menu bar item with `Open Onboarding`.

To skip all permission dialogs entirely, run once after building:

```bash
sudo make grant
```

This writes the grants directly to the TCC database so no popups ever appear.

The `.app` and `.dmg` targets default to ad-hoc signing so they work cleanly on the local machine. That is enough for local testing, but it still triggers Gatekeeper's "macOS can't verify this app is free from malware" block on other Macs.

To get the normal "This app was downloaded from the Internet" prompt instead, ship a Developer ID signed and notarized build:

```bash
./scripts/build-app.sh \
  --sign-mode developer-id \
  --sign-identity "Developer ID Application: Your Name (TEAMID)"

./scripts/notarize.sh \
  --path dist/HyperPointer.app \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"

./scripts/build-dmg.sh \
  --skip-build \
  --app-path dist/HyperPointer.app \
  --sign-mode developer-id \
  --sign-identity "Developer ID Application: Your Name (TEAMID)"

./scripts/notarize.sh \
  --path dist/HyperPointer.dmg \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"
```

The release workflow now follows that sequence automatically when the required GitHub secrets are configured.

## Sparkle Release Signing

The GitHub Actions release job signs the published DMG with Sparkle's Ed25519 key. It expects a `SPARKLE_PRIVATE_KEY` repository secret containing the exported private key contents, not the `sparkle:edSignature` output.

To create or recover the matching keypair:

```bash
swift package resolve
./.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

That command prints the public key to embed in `SUPublicEDKey` inside `Sources/Info.plist`. To export the private key for CI:

```bash
./.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
```

Copy the contents of `sparkle-private-key.txt` into the `SPARKLE_PRIVATE_KEY` GitHub secret, then delete the file. The release workflow reads that secret with `sign_update --ed-key-file -`, signs `dist/HyperPointer.dmg`, and writes the resulting signature into `appcast.xml`.

For public macOS releases you also need these GitHub secrets:

- `DEVELOPER_ID_APPLICATION_P12`
- `DEVELOPER_ID_APPLICATION_PASSWORD`
- `DEVELOPER_ID_APPLICATION_NAME`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

## Usage

- **Ctrl+Space** — Open the panel at your cursor
- **Hold ⌘** — Panel follows your cursor; release to anchor it and type
- **Cmd+right-click** — Open the panel at the clicked location

Once the panel appears, it shows context about the UI element under your cursor (app name, element role, hierarchy). Type a question and hit Enter to start a streaming conversation with Claude. Follow-up messages keep the same session context.

## Things to Try

- Hover over a button or menu item and ask "what does this do?"
- Select some code in your editor, right-click, and ask Claude to explain or refactor it
- Point at an error dialog and ask how to fix it
- Hover over a browser element to automatically capture the page URL as context
- Use follow-up messages to dig deeper without losing conversation context
