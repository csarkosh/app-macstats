#!/bin/sh
# notarize.sh ZIP: sends the zip (a bundle signed with a Developer ID, bundle.sh with
# CODESIGN_IDENTITY) to Apple's notary service, waits for the verdict, staples the ticket to the
# app beside the zip, and rewrites the zip from the stapled app.
#
# Credentials, one of:
#   NOTARY_KEY, NOTARY_KEY_ID, NOTARY_ISSUER   an App Store Connect API key (.p8 path, its id,
#                                              the issuer id), what the release workflow uses
#   NOTARY_PROFILE                             a keychain profile made once on this Mac with
#                                              xcrun notarytool store-credentials <profile>
set -eu
ZIP="$1"
OUT=$(dirname "$ZIP")
APP="$OUT/MacStats.app"
[ -d "$APP" ] || { echo "notarize.sh: $APP is not beside $ZIP" >&2; exit 1; }
if [ -n "${NOTARY_KEY:-}" ]; then
  set -- --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
elif [ -n "${NOTARY_PROFILE:-}" ]; then
  set -- --keychain-profile "$NOTARY_PROFILE"
else
  echo "notarize.sh: set NOTARY_KEY, NOTARY_KEY_ID and NOTARY_ISSUER, or NOTARY_PROFILE" >&2
  exit 1
fi
LOG=$(mktemp)
if ! xcrun notarytool submit "$ZIP" "$@" --wait --output-format json > "$LOG"; then
  cat "$LOG" >&2
  exit 1
fi
STATUS=$(sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p' "$LOG" | tail -1)
ID=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' "$LOG" | head -1)
if [ "$STATUS" != "Accepted" ]; then
  echo "notarize.sh: Apple said $STATUS for submission $ID; the log:" >&2
  xcrun notarytool log "$ID" "$@" >&2 || true
  exit 1
fi
# Only the zip's path goes to stdout: callers capture it (ZIP=$(... notarize.sh ...)).
# Apple has accepted the submission by now; stapling and validating only fetch its ticket from
# Apple's CloudKit service, which drops the connection from GitHub's runners now and then ("The
# network connection was lost", error 68: 1.2.0's first two runs, once in each step; Arkos
# retries the same way). The ticket is there, so each fetch is tried again rather than the
# release thrown away.
retry() {
  for TRY in 1 2 3 4 5; do
    if xcrun stapler "$1" "$APP" >&2; then
      return 0
    fi
    [ "$TRY" -lt 5 ] || { echo "notarize.sh: stapler $1 failed five times" >&2; exit 1; }
    echo "notarize.sh: stapler $1 failed (try $TRY of 5); again in $((TRY * 20)) s" >&2
    sleep $((TRY * 20))
  done
}
retry staple
retry validate
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "$ZIP"
