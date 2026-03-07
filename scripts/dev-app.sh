#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="HyperPointer"
IDENTITY_NAME="HyperPointer Local Development"
KEYCHAIN_PATH="$HOME/Library/Keychains/login.keychain-db"
RUN_AFTER_BUILD=0

if [[ "${1:-}" == "--run" ]]; then
  RUN_AFTER_BUILD=1
fi

identity_exists() {
  security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$IDENTITY_NAME\""
}

create_local_identity() {
  local tmpdir
  local export_password="hyperpointer-local-dev"
  tmpdir="$(mktemp -d)"

  cat > "$tmpdir/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no

[dn]
CN = $IDENTITY_NAME

[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

  openssl req \
    -newkey rsa:2048 \
    -nodes \
    -keyout "$tmpdir/key.pem" \
    -x509 \
    -days 3650 \
    -out "$tmpdir/cert.pem" \
    -config "$tmpdir/openssl.cnf" \
    >/dev/null 2>&1

  openssl pkcs12 \
    -export \
    -inkey "$tmpdir/key.pem" \
    -in "$tmpdir/cert.pem" \
    -out "$tmpdir/identity.p12" \
    -passout "pass:$export_password" \
    >/dev/null 2>&1

  security import "$tmpdir/identity.p12" \
    -k "$KEYCHAIN_PATH" \
    -P "$export_password" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    >/dev/null

  security add-trusted-cert \
    -d \
    -r trustRoot \
    -k "$KEYCHAIN_PATH" \
    "$tmpdir/cert.pem" \
    >/dev/null

  rm -rf "$tmpdir"
}

cd "$ROOT_DIR"
swift build

if ! identity_exists; then
  echo "Creating local code-signing identity: $IDENTITY_NAME"
  create_local_identity
fi

if ! identity_exists; then
  echo "Failed to create a usable code-signing identity." >&2
  exit 1
fi

BIN_DIR="$(swift build --show-bin-path)"
BINARY_PATH="$BIN_DIR/$APP_NAME"
APP_PATH="$ROOT_DIR/.build/$APP_NAME.app"
CONTENTS_PATH="$APP_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"

rm -rf "$APP_PATH"
mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"
cp "$BINARY_PATH" "$MACOS_PATH/$APP_NAME"
cp "$ROOT_DIR/Sources/Info.plist" "$CONTENTS_PATH/Info.plist"

codesign \
  --force \
  --deep \
  --sign "$IDENTITY_NAME" \
  --timestamp=none \
  "$APP_PATH"

echo "Built app bundle: $APP_PATH"

if [[ "$RUN_AFTER_BUILD" -eq 1 ]]; then
  open "$APP_PATH"
fi
