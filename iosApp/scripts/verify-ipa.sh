#!/bin/bash
# Check a sideload IPA the way a sideloader will read it: the signature verifies, and the app and
# each extension carry the app-group entitlement (the sideloader remaps it; without it the widget
# and share extension can't see the app's data). Prints the signature and entitlements for the log.
#   scripts/verify-ipa.sh build/BitChord-<version>-<build>.ipa
set -euo pipefail
IPA=${1:?usage: verify-ipa.sh <ipa>}
[ -f "$IPA" ] || { echo "no IPA at $IPA" >&2; exit 1; }

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
ditto -x -k "$IPA" "$DIR"
APP="$DIR/Payload/BitChord.app"
[ -d "$APP" ] || { echo "$IPA has no Payload/BitChord.app" >&2; exit 1; }

# --deep covers the extensions and frameworks; --strict rejects a bundle changed after signing.
codesign --verify --deep --strict --verbose=2 "$APP"
for b in "$APP" "$APP"/PlugIns/*.appex; do
  echo "== $(basename "$b")"
  codesign -dv "$b" 2>&1 | grep -E '^(Identifier|Signature|Format)=' || true
  ENT=$(codesign -d --entitlements :- "$b" 2>/dev/null)
  echo "$ENT"
  grep -q "group.com.music.bitchord" <<<"$ENT" \
    || { echo "$(basename "$b") lacks the app-group entitlement" >&2; exit 1; }
done
