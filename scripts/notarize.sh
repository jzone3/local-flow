#!/usr/bin/env bash
# Notarize one file with Apple's notary service and wait for the verdict.
# Submits without --wait, then polls up to NOTARY_TIMEOUT (default 2h) — Apple's queue
# sometimes takes well over 30 minutes. On any non-Accepted verdict, prints Apple's log.
# Needs NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID.
set -euo pipefail

file="$1"
timeout="${NOTARY_TIMEOUT:-2h}"
auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

submission=$(xcrun notarytool submit "$file" "${auth[@]}" --output-format json)
id=$(echo "$submission" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
echo "Submitted $file as $id; waiting up to $timeout"

status=$(xcrun notarytool wait "$id" "${auth[@]}" --timeout "$timeout" --output-format json \
  | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", "Unknown"))')
echo "Notarization status: $status"

if [ "$status" != "Accepted" ]; then
  xcrun notarytool log "$id" "${auth[@]}" || true
  exit 1
fi
