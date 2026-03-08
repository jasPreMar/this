# HyperPointer

We have a new kind of computer. It can write code, browse the web, manage files, send emails, and control applications. It's genuinely powerful. But right now, it lives in the command line. You open a chat window, start from a blank page, and describe what you want. Every time. The AI is capable, but it's blind — it doesn't know what's on your screen, what you're looking at, or what you're trying to act on. You have to explain the context yourself before you can give the command.

The interface is a bottleneck.

One fix is to start with objects instead of words. Your screen is full of them right now — apps, windows, icons, folders, buttons, text fields, images, links. These are the things you're actually trying to act on. If you could point at any one of them and issue a command — open this, rename that, summarize this, rewrite that, delete this, copy that, move this — you'd be giving the AI something it's currently missing: a target. A specific thing to work on, with full context already attached.

This isn't a new idea — it's actually the original idea behind the graphical user interface. When the first GUIs were designed, they were solving a similar problem. The command line was powerful but required you to know the exact syntax for every operation. The GUI made computing accessible by introducing four things: windows, icons, menus, and a pointer. The pointer let you aim at objects directly. The icons made those objects visible and recognizable. The menus revealed what you could do with them.

That model held up for decades. But menus were always a workaround — a fixed list of options decided in advance by whoever built the software. You were limited to commands they anticipated.

With AI, that limitation disappears. You're no longer choosing from a list. You can ask for anything, in plain language, and the system figures out how to do it. So the windows, icons, and pointer are still useful — the spatial, visual model of computing is still the best way to understand what's on your screen. But the menu is the part that can go. Replace it with a command. Replace the fixed list with a conversation. Keep the pointer, keep the objects, and let the AI handle the rest.
## Requirements

- macOS 14.0+ (Sonoma)
- [Claude CLI](https://github.com/anthropics/claude-code) installed
- Accessibility permissions granted to the app

## Setup

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

On first launch, macOS will prompt you to grant Accessibility and Screen Recording permissions. It will also show Automation permission dialogs for any apps currently running — click Allow for each. These are one-time prompts; macOS remembers your choices permanently.

To skip all permission dialogs entirely, run once after building:

```bash
sudo make grant
```

This writes the grants directly to the TCC database so no popups ever appear.

The `.app` and `.dmg` targets default to ad-hoc signing so they work cleanly on the local machine. If you want a distributable artifact for other Macs, pass a real Developer ID identity and notarize the result:

```bash
SIGN_MODE=identity SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make dmg
```

## Usage

- **Ctrl+Space** — Open the panel at your cursor
- **Right-click** — Intercept right-click to open the panel

Once the panel appears, you'll see context about the UI element under your cursor (app name, element role, hierarchy). Type a question and hit enter to start a streaming conversation with Claude. Follow-up messages keep the same session context.

## Things to Try

- Hover over a button or menu item and ask "what does this do?"
- Select some code in your editor, right-click, and ask Claude to explain or refactor it
- Point at an error dialog and ask how to fix it
- Hover over a browser element to automatically capture the page URL as context
- Use follow-up messages to dig deeper without losing conversation context
