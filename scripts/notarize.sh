#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_PATH=""
APPLE_ID="${APPLE_ID:-}"
TEAM_ID="${APPLE_TEAM_ID:-${TEAM_ID:-}}"
APP_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-${APP_PASSWORD:-}}"
KEYCHAIN_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
TEMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --path <path>                    App bundle, DMG, PKG, or ZIP to notarize
  --apple-id <email>              Apple ID for notarytool authentication
  --team-id <team-id>             Apple Developer Team ID
  --password <app-password>       App-specific password for the Apple ID
  --keychain-profile <profile>    Stored notarytool keychain profile to use instead
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      TARGET_PATH="${2:?missing value for --path}"
      shift 2
      ;;
    --apple-id)
      APPLE_ID="${2:?missing value for --apple-id}"
      shift 2
      ;;
    --team-id)
      TEAM_ID="${2:?missing value for --team-id}"
      shift 2
      ;;
    --password)
      APP_PASSWORD="${2:?missing value for --password}"
      shift 2
      ;;
    --keychain-profile)
      KEYCHAIN_PROFILE="${2:?missing value for --keychain-profile}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TARGET_PATH" ]]; then
  echo "--path is required." >&2
  exit 1
fi

if [[ ! -e "$TARGET_PATH" ]]; then
  echo "Notarization target not found: $TARGET_PATH" >&2
  exit 1
fi

AUTH_ARGS=()
if [[ -n "$KEYCHAIN_PROFILE" ]]; then
  AUTH_ARGS=(--keychain-profile "$KEYCHAIN_PROFILE")
else
  if [[ -z "$APPLE_ID" || -z "$TEAM_ID" || -z "$APP_PASSWORD" ]]; then
    echo "Provide either --keychain-profile or all of --apple-id, --team-id, and --password." >&2
    exit 1
  fi
  AUTH_ARGS=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD")
fi

ABS_TARGET_PATH="$(cd "$(dirname "$TARGET_PATH")" && pwd)/$(basename "$TARGET_PATH")"
SUBMIT_PATH="$ABS_TARGET_PATH"
STAPLE_PATH="$ABS_TARGET_PATH"

case "$ABS_TARGET_PATH" in
  *.app)
    ZIP_PATH="$TEMP_DIR/$(basename "$ABS_TARGET_PATH").zip"
    ditto -c -k --keepParent "$ABS_TARGET_PATH" "$ZIP_PATH"
    SUBMIT_PATH="$ZIP_PATH"
    ;;
  *.dmg|*.pkg)
    ;;
  *.zip)
    STAPLE_PATH=""
    ;;
  *)
    echo "Unsupported notarization target: $ABS_TARGET_PATH" >&2
    exit 1
    ;;
esac

xcrun notarytool submit "$SUBMIT_PATH" "${AUTH_ARGS[@]}" --wait

if [[ -n "$STAPLE_PATH" ]]; then
  xcrun stapler staple "$STAPLE_PATH"
  xcrun stapler validate "$STAPLE_PATH"
fi

case "$ABS_TARGET_PATH" in
  *.app)
    spctl -a -vvv --type exec "$ABS_TARGET_PATH"
    ;;
  *.dmg)
    spctl -a -vvv -t open "$ABS_TARGET_PATH"
    ;;
esac

echo "Notarized: $ABS_TARGET_PATH"
