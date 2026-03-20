#!/bin/zsh
set -euo pipefail

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  printf '%s\n' "$SIGN_IDENTITY"
  exit 0
fi

IDENTITIES_OUTPUT="$(security find-identity -v -p codesigning 2>/dev/null || true)"

extract_identity() {
  local pattern="$1"
  local line

  [[ -n "$pattern" ]] || return 1
  line="$(printf '%s\n' "$IDENTITIES_OUTPUT" | grep -F "$pattern" | head -n 1 || true)"
  [[ -n "$line" ]] || return 1

  printf '%s\n' "$line" | sed -E 's/^.*"([^"]+)".*$/\1/'
}

for pattern in \
  "${SIGN_IDENTITY_PATTERN:-}" \
  "Developer ID Application:" \
  "Apple Development:" \
  "HyperPointer Local Development" \
  "HyperPointer Dev"
do
  if identity_name="$(extract_identity "$pattern")"; then
    printf '%s\n' "$identity_name"
    exit 0
  fi
done

exit 1
