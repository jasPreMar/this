#!/bin/zsh
# One-time setup: create a self-signed code-signing certificate and export it
# so local builds can keep a stable signature across updates.
#
# Usage: ./scripts/create-signing-cert.sh [cert-name]
#   cert-name defaults to "HyperPointer"
#
# After running, add three GitHub repository secrets:
#   SIGNING_CERT_P12          — contents of the .p12.b64 file printed below
#   SIGNING_CERT_PASSWORD     — password printed by this script
#   SIGNING_CERT_NAME         — the cert name (e.g. "HyperPointer")
#
# Why this matters:
#   Ad-hoc signed apps get a TCC code requirement tied to the binary hash.
#   Every Sparkle update changes the binary, so the hash changes, and macOS
#   re-prompts for all permissions. A stable self-signed cert produces a
#   requirement tied to the cert anchor hash — stable across all builds
#   signed with the same cert. This is for local/dev use only and will not
#   remove Gatekeeper's malware warning on other Macs.
set -euo pipefail

CERT_NAME="${1:-HyperPointer}"
P12_FILE="${CERT_NAME// /_}.p12"
B64_FILE="${P12_FILE}.b64"
PASSWORD=$(openssl rand -base64 18)

echo ""
echo "Creating self-signed code-signing certificate: '$CERT_NAME'"
echo ""

TMPDIR_CERTS=$(mktemp -d)
KEY_FILE="$TMPDIR_CERTS/key.pem"
CERT_FILE="$TMPDIR_CERTS/cert.pem"

# Generate RSA key
openssl genrsa -out "$KEY_FILE" 2048 2>/dev/null

# Generate self-signed cert valid for 30 years
openssl req -new -x509 \
  -key "$KEY_FILE" \
  -out "$CERT_FILE" \
  -days 10950 \
  -subj "/CN=$CERT_NAME/O=$CERT_NAME/C=US" \
  -addext "keyUsage=critical,digitalSignature,keyCertSign" \
  -addext "extendedKeyUsage=codeSigning" 2>/dev/null

# Bundle into PKCS#12
openssl pkcs12 -export \
  -in "$CERT_FILE" \
  -inkey "$KEY_FILE" \
  -out "$P12_FILE" \
  -name "$CERT_NAME" \
  -passout "pass:$PASSWORD" 2>/dev/null

rm -rf "$TMPDIR_CERTS"

# Import into login keychain so local builds can sign immediately
# -A allows any application to access the key (avoids codesign prompts)
security import "$P12_FILE" \
  -k ~/Library/Keychains/login.keychain-db \
  -P "$PASSWORD" \
  -T /usr/bin/codesign \
  -A 2>/dev/null

# Base64-encode the p12 for GitHub Secrets
base64 < "$P12_FILE" > "$B64_FILE"

echo "============================================================"
echo "Certificate created and imported into your login keychain."
echo ""
echo "Add these three GitHub repository secrets:"
echo "  https://github.com/jasPreMar/hyper-pointer/settings/secrets/actions"
echo ""
echo "  SIGNING_CERT_NAME     = $CERT_NAME"
echo "  SIGNING_CERT_PASSWORD = $PASSWORD"
echo "  SIGNING_CERT_P12      = (run: pbcopy < $B64_FILE)"
echo "============================================================"
