#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HyperPointer"
CONFIGURATION="${BUILD_CONFIGURATION:-release}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
APP_PATH="$DIST_DIR/$APP_NAME.app"
INSTALL_AFTER_BUILD=0
RUN_AFTER_BUILD=0
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
SIGN_MODE="${SIGN_MODE:-auto}"
SIGNING_HELPER="$ROOT_DIR/scripts/detect-signing-identity.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --configuration <debug|release>  Build configuration (default: release)
  --output-dir <path>              Artifact directory (default: ./dist)
  --install                        Copy the built app into /Applications
  --run                            Open the built app after packaging
  --sign-identity <identity>       macOS signing identity to use
  --sign-mode <auto|ad-hoc|identity|skip>
                                   Signing mode (default: auto)
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
      shift 2
      ;;
    --install)
      INSTALL_AFTER_BUILD=1
      shift
      ;;
    --run)
      RUN_AFTER_BUILD=1
      shift
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

case "$SIGN_MODE" in
  auto|ad-hoc|identity|skip)
    ;;
  *)
    echo "Unsupported sign mode: $SIGN_MODE" >&2
    exit 1
    ;;
esac

resolve_signing_configuration() {
  local detected_identity=""

  if [[ -z "$SIGN_IDENTITY" && -x "$SIGNING_HELPER" ]]; then
    detected_identity="$("$SIGNING_HELPER" 2>/dev/null || true)"
  fi

  case "$SIGN_MODE" in
    auto)
      if [[ -n "$SIGN_IDENTITY" ]]; then
        SIGN_MODE="identity"
      elif [[ -n "$detected_identity" ]]; then
        SIGN_MODE="identity"
        SIGN_IDENTITY="$detected_identity"
      else
        SIGN_MODE="ad-hoc"
      fi
      ;;
    identity)
      if [[ -z "$SIGN_IDENTITY" && -n "$detected_identity" ]]; then
        SIGN_IDENTITY="$detected_identity"
      fi
      if [[ -z "$SIGN_IDENTITY" ]]; then
        echo "--sign-mode identity requires --sign-identity or a detectable signing identity." >&2
        exit 1
      fi
      ;;
  esac
}

resolve_signing_configuration

if [[ "$SIGN_MODE" == "identity" ]]; then
  echo "Using signing identity: $SIGN_IDENTITY"
else
  echo "Using signing mode: $SIGN_MODE"
fi

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION"

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
BINARY_PATH="$BIN_DIR/$APP_NAME"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"

rm -rf "$APP_PATH"
mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"
cp "$BINARY_PATH" "$MACOS_PATH/$APP_NAME"
cp "$ROOT_DIR/Sources/Info.plist" "$CONTENTS_PATH/Info.plist"
cp "$ROOT_DIR/Sources/Resources"/*.wav "$RESOURCES_PATH/"

RESOURCE_BUNDLE="$(find "$BIN_DIR" -maxdepth 1 -name "${APP_NAME}_*.bundle" -type d 2>/dev/null | head -1)"
if [[ -n "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_PATH/"
fi

# Embed Sparkle.framework (extracted by SPM into .build/artifacts/)
SPARKLE_FRAMEWORK="$(find "$ROOT_DIR/.build/artifacts" -name "Sparkle.framework" -type d 2>/dev/null | head -1)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  FRAMEWORKS_PATH="$CONTENTS_PATH/Frameworks"
  mkdir -p "$FRAMEWORKS_PATH"
  rm -rf "$FRAMEWORKS_PATH/Sparkle.framework"
  cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_PATH/"
fi

if [[ "$SIGN_MODE" != "skip" ]]; then
  xattr -cr "$APP_PATH" 2>/dev/null || true

  if [[ "$SIGN_MODE" == "identity" ]]; then
    SIGN_ARG="$SIGN_IDENTITY"
  else
    SIGN_ARG="-"
  fi

  # Sign nested components before the app bundle
  if [[ -d "$CONTENTS_PATH/Frameworks/Sparkle.framework" ]]; then
    # Sign XPC services inside Sparkle
    find "$CONTENTS_PATH/Frameworks/Sparkle.framework" -name "*.xpc" -type d | while read xpc; do
      codesign --force --sign "$SIGN_ARG" --timestamp=none "$xpc"
    done
    codesign --force --sign "$SIGN_ARG" --timestamp=none "$CONTENTS_PATH/Frameworks/Sparkle.framework"
  fi

  codesign \
    --force \
    --deep \
    --sign "$SIGN_ARG" \
    --timestamp=none \
    "$APP_PATH"
fi

echo "Built app bundle: $APP_PATH"

if [[ "$INSTALL_AFTER_BUILD" -eq 1 ]]; then
  INSTALL_DIR="${INSTALL_DIR:-/Applications}"
  TARGET_PATH="$INSTALL_DIR/$APP_NAME.app"
  rm -rf "$TARGET_PATH"
  ditto "$APP_PATH" "$TARGET_PATH"
  echo "Installed app bundle: $TARGET_PATH"
fi

if [[ "$RUN_AFTER_BUILD" -eq 1 ]]; then
  RUN_PATH="$APP_PATH"
  if [[ "$INSTALL_AFTER_BUILD" -eq 1 ]]; then
    RUN_PATH="$TARGET_PATH"
  fi
  open -na "$RUN_PATH"
fi
