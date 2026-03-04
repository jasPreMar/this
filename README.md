# HyperPointer

A macOS utility that lets you right-click or hotkey on any UI element and ask Claude about it. It uses the Accessibility API to capture context about what's under your cursor — the element hierarchy, selected text, browser URLs — and streams a conversation with Claude right in a floating panel.

## Requirements

- macOS 14.0+ (Sonoma)
- [Claude CLI](https://github.com/anthropics/claude-code) installed
- Accessibility permissions granted to the app

## Setup

```bash
git clone https://github.com/jasPreMar/hyper-pointer.git
cd hyper-pointer
swift build
./.build/arm64-apple-macosx/debug/HyperPointer
```

On first launch, macOS will prompt you to grant Accessibility permissions. Go to **System Settings → Privacy & Security → Accessibility** and enable HyperPointer.

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
