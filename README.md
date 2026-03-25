# This

## Problem

### Argument #1 - Pointing & Specifity

Language is more ergonomic than any computer interface. By teaching computers language, we've gotten more ergonomic computers. But it can feel cumberson. Typing is prone to typos. Takes coordination.

Spoken language is more ergonomic than written language. We learn to speak years before we learn to write or type. Speaking is easier, more natural, and more freeing. We can do other things while we speak. But we lose a lot of specificity.

But long before we ever utter a word, we look at things, point at things, and demand things. That loop: Look, point, and demand. We can do most of this in our GUIs. We have objects. We have a pointer. And we have a way to demand... *click click*.

When we speak, why not use out freed up digits to point, and make that visible to the LLM? My hypothesis is that these two forms of communication, done at the exact same time, will result in an extremely fluid and highly controllable interface.

### Argument #2 - Objets & Orientation

Classic command line interfaces had two big problems: Memorization and imagination. 

**Memorization:**
We had to memorize the syntax for every operation. If you get it wrong, you get an error. 

**Imagination:**
And we had to imagine what's possible rather than discover it. We had to hold what was possible in our head before feeling confident enough to try it.

GUIs solved both. Objects can easily be depicted with metaphors: folders, files, and icons scattered across on a desk. An object then only has a limited number of possible commands that followed. With text, you can cut, copy, and paste, not open or trash. With folders, you can open, duplicate, or rename, not run or refresh. Going object-first made possibilities discoverable.

As GUIs become ubiquitous, they also became more complex and speciated. You had to learn to use software to get more and more things done, which can be exausting (not to mention, expensive).

So now we have AI. It can use GUIs so we don't have to learn it. It can interpret what we're saying, so we don't have to memorize anything. But the problem of imagination remains. Beacuse we're back to the command-line, we're limited by ability to imagine what's possible.

This is wby I believe objects should come back into play. By orienting an agent in an object, we collapse the space of possible actions. It's less cognitively demanding.

---

## Introducing This

This lets you launch an agent from any object. Objects are anything you point at. You can already point at a file left click to select it. You can double click to open it. You can right click to see a menu of other possible actions, like rename. But now, with This, you can point at it, and with your voice, tell it to open, select all contents, copy those contents, and move them to another folder in another part of your drive and duplicated with a slightly different scheme based on that folder's name. You can point at your browser and tell it what website to go to, what to do when you get there, to copy the contents, and bring it back to this other notes application and based the results.

If your cursor is an arrow, clicking is a spear, and This is a long bow. Or better yet, This turns your arrow into a fully autonomous drone capable of entire chains of action, and returns to you when it's done.

If This is done well, we shouldn't need context menus (right click menus) anymore — except in the case of generated contextual ones that aid the user's need to choose an action. In fact, I'd argue that we don't need static menus at all anymore. You can start from an objecct and ask for anything you want, in plain language, and the system figures out how to do it.

---

## How it works

Normally, using an AI assistant goes like this:

1. See something on screen
2. Switch to a chat window
3. Type: *"I'm in VS Code, looking at a red error in the Problems panel that says 'Cannot find module'..."*
4. Ask your question

You spend half your effort just describing the context before you can even ask the question.

This removes that step:

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

That downloads the latest DMG from GitHub Releases, installs `This.app`, opens it, and launches the onboarding wizard.

To build from source:

```bash
git clone https://github.com/jasPreMar/hyper-pointer.git
cd hyper-pointer
make build
./.build/debug/This
```

For permission testing, prefer launching the packaged app bundle instead of the raw binary so macOS sees a stable app path and signing identity:

```bash
./scripts/dev-app.sh --run
```

To package it as a normal macOS app bundle:

```bash
make app
open dist/This.app
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
open dist/This.dmg
```

For local permission persistence across updates, a self-signed identity is enough. For distribution to other Macs, it is not. Gatekeeper's malware warning only goes away when the shipped artifacts are signed with a real `Developer ID Application` certificate, notarized, and stapled.

On first launch, This opens an onboarding wizard that walks through:

- Installing or verifying Claude CLI
- Accessibility
- Screen Recording
- Optional microphone and speech permissions for invoke-key dictation
- Optional Automation approvals for the apps you want This to control

You can reopen the wizard any time from the menu bar item with `Open Onboarding`.

To skip all permission dialogs entirely, run once after building:

```bash
sudo make grant
```

This writes the grants directly to the TCC database so no popups ever appear.

The `.app` and `.dmg` targets now auto-prefer the best available signing identity in your keychain, starting with `Developer ID Application`, then local development identities. If no stable identity is available they fall back to ad-hoc signing. For a distributable artifact on other Macs, use your real Developer ID identity and notarize the result:

```bash
./scripts/build-app.sh \
  --sign-mode developer-id \
  --sign-identity "Developer ID Application: Your Name (TEAMID)"

./scripts/notarize.sh \
  --path dist/This.app \
  --apple-id "you@example.com" \
  --team-id "TEAMID" \
  --password "app-specific-password"

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

If you prefer `notarytool` keychain profiles, `scripts/notarize.sh` also accepts `--keychain-profile <profile>`.

## Sparkle Release Signing

The GitHub Actions release job signs the published DMG with Sparkle's Ed25519 key. It expects a `SPARKLE_PRIVATE_KEY` repository secret containing the exported private key contents, not the `sparkle:edSignature` output.

The release workflow also requires these secrets for Gatekeeper-safe distribution:

- `DEVELOPER_ID_APPLICATION_P12`
- `DEVELOPER_ID_APPLICATION_PASSWORD`
- `DEVELOPER_ID_APPLICATION_NAME`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

To create or recover the matching keypair:

```bash
swift package resolve
./.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

That command prints the public key to embed in `SUPublicEDKey` inside `Sources/Info.plist`. To export the private key for CI:

```bash
./.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
```

Copy the contents of `sparkle-private-key.txt` into the `SPARKLE_PRIVATE_KEY` GitHub secret, then delete the file. The release workflow reads that secret with `sign_update --ed-key-file -`, signs `dist/This.dmg`, and writes the resulting signature into `appcast.xml`.

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
