#!/bin/zsh
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
TARGET_PATH=""
APPLE_ID="${APPLE_ID:-}"
TEAM_ID="${APPLE_TEAM_ID:-${TEAM_ID:-}}"
PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-${PASSWORD:-}}"
KEYCHAIN_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-${KEYCHAIN_PROFILE:-}}"
TEMP_DIR=""

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME --path <artifact> [options]

Options:
  --path <artifact>                Path to the app or DMG to notarize
  --apple-id <email>              Apple ID used for notarization
  --team-id <team-id>             Apple Developer Team ID
  --password <app-password>       Apple app-specific password
  --keychain-profile <profile>    notarytool keychain profile to use instead
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
      PASSWORD="${2:?missing value for --password}"
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
  usage >&2
  exit 1
fi

if [[ ! -e "$TARGET_PATH" ]]; then
  echo "Artifact does not exist: $TARGET_PATH" >&2
  exit 1
fi

submit_target="$TARGET_PATH"

if [[ -d "$TARGET_PATH" && "$TARGET_PATH" == *.app ]]; then
  TEMP_DIR="$(mktemp -d)"
  submit_target="$TEMP_DIR/$(basename "$TARGET_PATH").zip"

  echo "Creating notarization archive: $submit_target"
  ditto -c -k --keepParent --sequesterRsrc "$TARGET_PATH" "$submit_target"
fi

submit_args=("$submit_target" --wait)

if [[ -n "$KEYCHAIN_PROFILE" ]]; then
  submit_args+=(--keychain-profile "$KEYCHAIN_PROFILE")
else
  if [[ -z "$APPLE_ID" || -z "$TEAM_ID" || -z "$PASSWORD" ]]; then
    echo "Provide either --keychain-profile or all of --apple-id, --team-id, and --password." >&2
    exit 1
  fi
  submit_args+=(
    --apple-id "$APPLE_ID"
    --team-id "$TEAM_ID"
    --password "$PASSWORD"
  )
fi

echo "Submitting for notarization: $submit_target"
xcrun notarytool submit "${submit_args[@]}"

echo "Stapling ticket: $TARGET_PATH"
xcrun stapler staple -v "$TARGET_PATH"

echo "Validating stapled ticket: $TARGET_PATH"
xcrun stapler validate -v "$TARGET_PATH"
