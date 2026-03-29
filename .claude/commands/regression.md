A regression has been discovered. Your job is to document it so it never happens again.

## Instructions

1. Ask the user: "What regressed? Describe the broken behavior in one sentence."
   - If the user already described it in the message, skip this step.

2. Search the codebase to find the relevant code. Identify:
   - Which file(s) and function(s) are involved
   - What the correct behavior looks like in the current code
   - What the broken state would look like

3. Append a new entry to `REGRESSIONS.md`. Use this format:

   ---

   ## N. [Short Title]

   **Correct:** [What should happen]

   **Where:** [File path] — [function/view name]

   **Assertions:**
   - [Specific code assertion 1]
   - [Specific code assertion 2]

   **Broken state:** [What happens when this regresses]

   - Increment the entry number from the last entry in the file.
   - **NEVER remove or modify existing entries.**

4. If the regression involves pure logic that can be tested without system APIs (macOS Accessibility, CGWindowList, SwiftUI views), also add a Swift test:
   - Add the test to the appropriate file in `Tests/ThisTests/`
   - If needed, extract logic into `Sources/ThisCore/` first
   - The test must fail when the regression is present and pass when the code is correct

5. Run `swift test` to verify all tests pass.

6. Commit with message: `guard: add regression check for [short description]`
