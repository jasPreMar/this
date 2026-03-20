#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HyperPointer"
SCRIPT_NAME="$(basename "$0")"
CONFIGURATION="${BUILD_CONFIGURATION:-release}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
VOLUME_NAME="${DMG_VOLUME_NAME:-$APP_NAME}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SIGN_MODE="${SIGN_MODE:-auto}"
SKIP_BUILD=0
SIGNING_HELPER="$ROOT_DIR/scripts/detect-signing-identity.sh"
TEMP_DIR="$(mktemp -d)"
STAGING_DIR="$TEMP_DIR/staging"
RW_DMG_PATH="$TEMP_DIR/$APP_NAME-rw.dmg"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

is_developer_id_identity() {
  [[ "$1" == Developer\ ID\ Application:* ]]
}

resolve_dmg_signing_configuration() {
  local detected_identity=""

  if [[ -z "$SIGN_IDENTITY" && -x "$SIGNING_HELPER" ]]; then
    detected_identity="$("$SIGNING_HELPER" 2>/dev/null || true)"
  fi

  case "$SIGN_MODE" in
    auto)
      if [[ -n "$SIGN_IDENTITY" ]] && is_developer_id_identity "$SIGN_IDENTITY"; then
        SIGN_MODE="developer-id"
      elif [[ -n "$detected_identity" ]] && is_developer_id_identity "$detected_identity"; then
        SIGN_MODE="developer-id"
        SIGN_IDENTITY="$detected_identity"
      fi
      ;;
    developer-id)
      if [[ -z "$SIGN_IDENTITY" && -n "$detected_identity" ]]; then
        SIGN_IDENTITY="$detected_identity"
      fi
      if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "--sign-mode developer-id requires --sign-identity or a detectable signing identity." >&2
        exit 1
      fi
      if ! is_developer_id_identity "$SIGN_IDENTITY"; then
        echo "--sign-mode developer-id requires a 'Developer ID Application:' certificate." >&2
        exit 1
      fi
      ;;
  esac
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --configuration <debug|release>  Build configuration (default: release)
  --output-dir <path>              Artifact directory (default: ./dist)
  --app-path <path>                Existing .app bundle to package
  --skip-build                     Reuse the existing app bundle at --app-path
  --volume-name <name>             Mounted DMG volume name (default: HyperPointer)
  --sign-identity <identity>       macOS signing identity to use for the app build
  --sign-mode <auto|ad-hoc|identity|developer-id|skip>
                                   Signing mode passed through to build-app.sh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      CONFIGURATION="${2:?missing value for --configuration}"
      shift 2
      ;;
    --output-dir)
      DIST_DIR="${2:?missing value for --output-dir}"
      APP_PATH="$DIST_DIR/$APP_NAME.app"
      DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
      shift 2
      ;;
    --app-path)
      APP_PATH="${2:?missing value for --app-path}"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --volume-name)
      VOLUME_NAME="${2:?missing value for --volume-name}"
      shift 2
      ;;
    --sign-identity)
      SIGN_IDENTITY="${2:?missing value for --sign-identity}"
      shift 2
      ;;
    --sign-mode)
      SIGN_MODE="${2:?missing value for --sign-mode}"
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

resolve_dmg_signing_configuration

mkdir -p "$DIST_DIR" "$STAGING_DIR"

if [[ "$SKIP_BUILD" -eq 1 ]]; then
  if [[ ! -d "$APP_PATH" ]]; then
    echo "--skip-build requires an existing app bundle at $APP_PATH" >&2
    exit 1
  fi
else
  build_app_args=(
    --configuration "$CONFIGURATION"
    --output-dir "$DIST_DIR"
    --sign-mode "$SIGN_MODE"
  )

  if [[ -n "$SIGN_IDENTITY" ]]; then
    build_app_args+=(--sign-identity "$SIGN_IDENTITY")
  fi

  "$ROOT_DIR/scripts/build-app.sh" "${build_app_args[@]}"
fi

ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
rm -f "$DMG_PATH"

hdiutil create \
  -quiet \
  -fs HFS+ \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDRW \
  "$RW_DMG_PATH"

hdiutil convert \
  -quiet \
  "$RW_DMG_PATH" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH"

if [[ "$SIGN_MODE" == "developer-id" ]]; then
  if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "--sign-mode developer-id requires --sign-identity when packaging a DMG." >&2
    exit 1
  fi

  xattr -cr "$DMG_PATH" 2>/dev/null || true
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

echo "Built installer image: $DMG_PATH"
