# macOS Gatekeeper And Notarization Checklist

## Goal

Ship This so users see the normal:

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

- Local build scripts now support a separate `developer-id` signing mode for distributable artifacts.
- The release workflow now requires Developer ID certificate secrets and notarizes both the `.app` and `.dmg`.
- A release from `main` should now fail loudly if those secrets are missing instead of silently publishing an ad-hoc build.

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

## What To Do Next

1. Create or download the `Developer ID Application` certificate.
2. Export it as a `.p12`.
3. Add the Apple and certificate secrets to GitHub.
4. Confirm the Apple ID used for notarization has 2FA enabled and an app-specific password.
5. Generate or verify the Sparkle signing keypair.
6. Run one notarized release from `main` and verify the downloaded DMG opens with the normal internet-download prompt instead of the malware block.

## Local Commands

Build app bundle locally:

```bash
./scripts/build-app.sh --sign-mode skip
```

Build DMG from an existing local app:

```bash
./scripts/build-dmg.sh --skip-build --app-path dist/This.app --sign-mode skip
```

Developer ID + notarization flow:

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

## One-Line Summary

There is no public shortcut around Apple's process: to move from the malware block to the normal first-open prompt, This must ship as a Developer ID signed, notarized, stapled macOS release, and the release pipeline now enforces that path.
