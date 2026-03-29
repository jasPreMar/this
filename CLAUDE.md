# This — AI Coding Guidelines

## Build & Test

```
swift build          # Build the app
swift run ThisTests           # Run regression tests (MUST pass before completing any task)
make run             # Build, sign, and run
```

## Regression Tracking

This project uses `REGRESSIONS.md` to track behaviors that have regressed before.

- **Before completing any task:** run `swift run ThisTests`
- **When fixing a bug:** check if it should be added to `REGRESSIONS.md` — use `/regression` to add an entry
- **Never remove entries** from `REGRESSIONS.md`
- **Never modify existing tests** in `Tests/ThisTests/` without flagging to the user — these guard against known regressions

## Project Structure

- `Sources/` — main app code (SwiftUI, macOS)
- `Sources/ThisCore/` — extracted pure logic (testable without system APIs)
- `Tests/ThisTests/` — regression test suite
- `REGRESSIONS.md` — human + AI readable regression checklist
- `.claude/commands/regression.md` — `/regression` slash command
