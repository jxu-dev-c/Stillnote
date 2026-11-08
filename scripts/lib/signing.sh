# Shared code-signing helpers; source from a script whose working directory is the repository.
#
# Releases are signed with one persistent certificate so the app's designated requirement
# (identifier + certificate hash) is identical from build to build. macOS privacy (TCC) grants
# are keyed on that requirement, so microphone and screen/system audio permissions survive
# upgrades. Without STILLNOTE_SIGNING_IDENTITY the signature is ad-hoc: its requirement is the
# build's own code hash, and every rebuild looks like a new app to TCC.

STILLNOTE_BUNDLE_ID='local.stillnote.app'
STILLNOTE_PINNED_CERT='packaging/signing/stillnote-release.cer'

# sign_code TARGET [codesign options...]
sign_code() {
  local target="$1"
  shift
  local identity="${STILLNOTE_SIGNING_IDENTITY:--}"
  local args=(--force --sign "$identity")
  if [[ "$identity" != - ]]; then
    # A self-signed certificate gains nothing from Apple's timestamp service, and skipping it
    # keeps signing offline.
    args+=(--timestamp=none)
    [[ -z "${STILLNOTE_SIGNING_KEYCHAIN:-}" ]] || args+=(--keychain "$STILLNOTE_SIGNING_KEYCHAIN")
  fi
  codesign "${args[@]}" "$@" "$target"
}

# Prints the uppercase hex SHA-1 of the committed release certificate.
pinned_cert_sha1() {
  /usr/bin/openssl x509 -inform der -in "$STILLNOTE_PINNED_CERT" -noout -fingerprint -sha1 \
    | sed 's/.*=//; s/://g' | tr '[:lower:]' '[:upper:]'
}

# The requirement every release-signed binary must satisfy.
pinned_requirement() {
  local identifier="$1"
  printf 'identifier "%s" and certificate leaf = H"%s"' "$identifier" "$(pinned_cert_sha1)"
}
