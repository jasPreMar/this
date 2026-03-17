# macOS Gatekeeper And Notarization Checklist

## Goal

Ship HyperPointer so users see the normal:

- "This app was downloaded from the Internet. Are you sure you want to open it?"

Instead of the blocking warning:

- "macOS can't confirm this app is free from malware"

## What Causes The Difference

To get the normal first-open prompt for a downloaded DMG, the release needs:

1. A real `Developer ID Application` certificate
2. Hardened runtime enabled
3. Apple notarization
4. Stapling the notarization ticket to the `.app` and `.dmg`

Ad-hoc signing and self-signed certificates are fine for local testing, but they do not remove the Gatekeeper malware warning for other Macs.

## Current Status

- Repo packaging and release workflow have been updated for Developer ID signing and notarization.
- Apple Developer account approval is still pending.
- Actual certificate creation and notarization are blocked until Apple finishes account activation.

## Files Already Added Or Updated

- `scripts/build-app.sh`
- `scripts/build-dmg.sh`
- `scripts/notarize.sh`
- `config/macos/distribution.entitlements`
- `.github/workflows/release.yml`
- `README.md`

## GitHub Secrets Needed

- `DEVELOPER_ID_APPLICATION_P12`
- `DEVELOPER_ID_APPLICATION_PASSWORD`
- `DEVELOPER_ID_APPLICATION_NAME`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `SPARKLE_PRIVATE_KEY`

## What To Do While Waiting For Apple Approval

1. Confirm the Apple ID you will use for notarization has 2FA enabled.
2. Decide whether CI will use:
   - Apple ID + app-specific password
   - App Store Connect API key + `notarytool` keychain profile
3. Create the GitHub secret placeholders listed above.
4. Generate or verify the Sparkle signing keypair.
5. Keep testing local `.app` and `.dmg` builds.

## Release Flow Once Apple Approves The Account

1. Create or download the `Developer ID Application` certificate.
2. Export it as a `.p12`.
3. Add the Apple and certificate secrets to GitHub.
4. Build the app with Developer ID signing.
5. Notarize and staple the `.app`.
6. Build the DMG from the stapled app.
7. Notarize and staple the `.dmg`.
8. Publish the release.

## Local Commands

Build app bundle locally:

```bash
./scripts/build-app.sh --sign-mode skip
```

Build DMG from an existing local app:

```bash
./scripts/build-dmg.sh --skip-build --app-path dist/HyperPointer.app --sign-mode skip
```

Developer ID + notarization flow:

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

## One-Line Summary

There is no public shortcut around Apple's process: to move from the malware block to the normal first-open prompt, HyperPointer must ship as a Developer ID signed, notarized, stapled macOS release.
