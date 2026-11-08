#!/usr/bin/env bash
# Imports the release signing identity into a temporary keychain for ./scripts/package-app.sh.
#
# Reads STILLNOTE_SIGNING_P12_BASE64 and STILLNOTE_SIGNING_P12_PASSWORD (repository secrets made by
# ./scripts/create-signing-identity.sh). In GitHub Actions it exports STILLNOTE_SIGNING_IDENTITY and
# STILLNOTE_SIGNING_KEYCHAIN to later steps; elsewhere it prints the matching export lines.
# Remove the keychain afterwards with: security delete-keychain "$STILLNOTE_SIGNING_KEYCHAIN"
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/signing.sh
if [[ -z "${STILLNOTE_SIGNING_P12_BASE64:-}" || -z "${STILLNOTE_SIGNING_P12_PASSWORD:-}" ]]; then
  if [[ "${STILLNOTE_RELEASE:-}" == true ]]; then
    echo 'STILLNOTE_SIGNING_P12_BASE64 and STILLNOTE_SIGNING_P12_PASSWORD are not set. An ad-hoc' >&2
    echo 'release would make every user grant capture permissions again; see docs/RELEASE.md.' >&2
    exit 1
  fi
  echo 'No release signing identity is configured; this build stays ad-hoc signed.' >&2
  exit 0
fi
scratch="${RUNNER_TEMP:-$(mktemp -d)}"
keychain="$scratch/stillnote-signing.keychain-db"
p12="$(mktemp "$scratch/stillnote-signing.XXXXXX")"
trap 'rm -f "$p12"' EXIT
printf '%s' "$STILLNOTE_SIGNING_P12_BASE64" | base64 -D > "$p12"
keychain_password="$(/usr/bin/openssl rand -hex 24)"
security delete-keychain "$keychain" 2>/dev/null || true
security create-keychain -p "$keychain_password" "$keychain"
# Keep it unlocked for the whole build; the default locks after five minutes.
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$p12" -k "$keychain" -f pkcs12 -P "$STILLNOTE_SIGNING_P12_PASSWORD" \
  -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a UI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" \
  "$keychain" >/dev/null
# codesign resolves the certificate chain through the search list, so add the keychain there.
existing=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%\"}"
  line="${line#\"}"
  [[ -z "$line" || "$line" == "$keychain" ]] || existing+=("$line")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain" "${existing[@]}"
identity="$(security find-certificate -a -Z "$keychain" | awk '/^SHA-1 hash:/ { print $3 }')"
[[ "$(wc -w <<<"$identity" | tr -d ' ')" == 1 ]] \
  || { echo 'The signing bundle must hold exactly one certificate.' >&2; exit 1; }
expected="$(pinned_cert_sha1)"
if [[ "$identity" != "$expected" ]]; then
  echo "The signing secret holds certificate $identity, but $STILLNOTE_PINNED_CERT pins $expected." >&2
  echo 'Shipping a different certificate would make every user grant permissions again.' >&2
  security delete-keychain "$keychain"
  exit 1
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "STILLNOTE_SIGNING_IDENTITY=$identity" >> "$GITHUB_ENV"
  echo "STILLNOTE_SIGNING_KEYCHAIN=$keychain" >> "$GITHUB_ENV"
else
  echo "export STILLNOTE_SIGNING_IDENTITY=$identity"
  echo "export STILLNOTE_SIGNING_KEYCHAIN='$keychain'"
fi
echo "Imported release signing certificate $identity" >&2
