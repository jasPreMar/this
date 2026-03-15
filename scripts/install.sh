#!/bin/zsh
set -euo pipefail

APP_NAME="HyperPointer"
REPO="${HYPERPOINTER_REPO:-jasPreMar/hyper-pointer}"
DMG_URL="https://github.com/${REPO}/releases/latest/download/${APP_NAME}.dmg"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
TMP_DIR="$(mktemp -d)"
DMG_PATH="$TMP_DIR/${APP_NAME}.dmg"
MOUNT_POINT=""

cleanup() {
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "${APP_NAME} currently supports macOS only." >&2
  exit 1
fi

if [[ "$INSTALL_DIR" == "/Applications" && ! -w "$INSTALL_DIR" ]]; then
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
  echo "Falling back to $INSTALL_DIR because /Applications is not writable."
else
  mkdir -p "$INSTALL_DIR"
fi

echo "Downloading ${APP_NAME}..."
curl -fL "$DMG_URL" -o "$DMG_PATH"

echo "Mounting installer image..."
ATTACH_OUTPUT="$(hdiutil attach "$DMG_PATH" -nobrowse)"
MOUNT_POINT="$(printf '%s\n' "$ATTACH_OUTPUT" | awk 'END {print $NF}')"

APP_SOURCE="$MOUNT_POINT/${APP_NAME}.app"
APP_DEST="$INSTALL_DIR/${APP_NAME}.app"

if [[ ! -d "$APP_SOURCE" ]]; then
  echo "Mounted image did not contain ${APP_NAME}.app." >&2
  exit 1
fi

echo "Installing to $APP_DEST..."
rm -rf "$APP_DEST"
ditto "$APP_SOURCE" "$APP_DEST"

echo "Opening ${APP_NAME}..."
open "$APP_DEST"

cat <<EOF

Installed ${APP_NAME} to:
  $APP_DEST

On first launch, HyperPointer opens its onboarding wizard to walk through Claude CLI,
Accessibility, Screen Recording, and optional Automation approvals.
EOF
