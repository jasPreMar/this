#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HyperPointer"
CONFIGURATION="${BUILD_CONFIGURATION:-release}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
VOLUME_NAME="${DMG_VOLUME_NAME:-$APP_NAME}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SIGN_MODE="${SIGN_MODE:-ad-hoc}"
SKIP_BUILD=0
TEMP_DIR="$(mktemp -d)"
STAGING_DIR="$TEMP_DIR/staging"
RW_DMG_PATH="$TEMP_DIR/$APP_NAME-rw.dmg"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --configuration <debug|release>  Build configuration (default: release)
  --output-dir <path>              Artifact directory (default: ./dist)
  --app-path <path>                Existing app bundle to package (default: ./dist/HyperPointer.app)
  --volume-name <name>             Mounted DMG volume name (default: HyperPointer)
  --sign-identity <identity>       macOS signing identity to use for the app build
  --sign-mode <ad-hoc|identity|developer-id|skip>
                                   Signing mode passed through to build-app.sh
  --skip-build                     Package the existing app bundle without rebuilding it
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
    --skip-build)
      SKIP_BUILD=1
      shift
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

case "$SIGN_MODE" in
  ad-hoc|identity|developer-id|skip)
    ;;
  *)
    echo "Unsupported sign mode: $SIGN_MODE" >&2
    exit 1
    ;;
esac

if [[ "$SIGN_MODE" == "developer-id" && -z "$SIGN_IDENTITY" ]]; then
  echo "--sign-mode developer-id requires --sign-identity." >&2
  exit 1
fi

mkdir -p "$DIST_DIR" "$STAGING_DIR"

build_app_args=(
  --configuration "$CONFIGURATION"
  --output-dir "$DIST_DIR"
  --sign-mode "$SIGN_MODE"
)

if [[ -n "$SIGN_IDENTITY" ]]; then
  build_app_args+=(--sign-identity "$SIGN_IDENTITY")
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  "$ROOT_DIR/scripts/build-app.sh" "${build_app_args[@]}"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
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
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

echo "Built installer image: $DMG_PATH"
