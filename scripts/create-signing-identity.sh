#!/usr/bin/env bash
# One-time maintainer setup: creates Stillnote's persistent self-signed release certificate.
#
# The private key and its password go to OUTPUT_DIR, which must be outside the repository; store
# them as GitHub Actions secrets and back them up offline. The public certificate is written to
# packaging/signing/stillnote-release.cer and committed, which pins the release identity.
# Replacing the certificate changes the app's designated requirement, so every user would have
# to grant capture permissions once more. Only rotate it deliberately.
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"
source scripts/lib/signing.sh
if [[ $# != 1 ]]; then
  echo "Usage: $0 OUTPUT_DIR   (a new directory outside this repository)" >&2
  exit 1
fi
[[ ! -e "$1" ]] || { echo "$1 already exists; choose a new directory." >&2; exit 1; }
[[ -d "$(dirname "$1")" ]] || { echo "$(dirname "$1") does not exist." >&2; exit 1; }
output="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
case "$output/" in
  "$(cd "$repo" && pwd -P)/"*) echo 'OUTPUT_DIR must be outside the repository.' >&2; exit 1 ;;
esac
if [[ -e "$STILLNOTE_PINNED_CERT" && "${STILLNOTE_ROTATE_SIGNING_IDENTITY:-}" != true ]]; then
  echo "$STILLNOTE_PINNED_CERT already exists. Rotating it makes every user re-grant permissions;" >&2
  echo 'set STILLNOTE_ROTATE_SIGNING_IDENTITY=true to do so deliberately.' >&2
  exit 1
fi
umask 077
mkdir -m 700 "$output"
config="$output/openssl.cnf"
cat > "$config" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Stillnote Release Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
# /usr/bin/openssl is LibreSSL, whose PKCS#12 encryption `security import` accepts on every
# supported macOS. Homebrew's OpenSSL 3 defaults to an encoding older releases reject.
/usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$config" \
  -keyout "$output/key.pem" -out "$output/cert.pem" 2>/dev/null
/usr/bin/openssl rand -base64 32 | tr -d '\n' > "$output/p12-password.txt"
/usr/bin/openssl pkcs12 -export -name 'Stillnote Release Signing' \
  -inkey "$output/key.pem" -in "$output/cert.pem" \
  -passout "file:$output/p12-password.txt" -out "$output/stillnote-signing.p12"
base64 -i "$output/stillnote-signing.p12" | tr -d '\n' > "$output/stillnote-signing.p12.base64"
rm -f "$output/key.pem" "$config"
mkdir -p "$(dirname "$STILLNOTE_PINNED_CERT")"
(umask 022 && /usr/bin/openssl x509 -in "$output/cert.pem" -outform der -out "$STILLNOTE_PINNED_CERT")
rm -f "$output/cert.pem"
cat <<MSG
Created the Stillnote release signing identity.
  Certificate SHA-1: $(pinned_cert_sha1)
  Public certificate (commit this): $STILLNOTE_PINNED_CERT
  Private key bundle (keep secret, back up offline): $output/stillnote-signing.p12

Store it as repository secrets:
  gh secret set STILLNOTE_SIGNING_P12_BASE64 < "$output/stillnote-signing.p12.base64"
  gh secret set STILLNOTE_SIGNING_P12_PASSWORD < "$output/p12-password.txt"
MSG
