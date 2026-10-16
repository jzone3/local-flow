#!/usr/bin/env bash
# Download the prebuilt whisper.cpp xcframework (Metal + Accelerate, macOS arm64/x86_64) into Vendor/.
# Pinned to a whisper.cpp build tag; the zip's SHA-256 is checked before anything is unpacked.
set -euo pipefail

WHISPER_TAG="${WHISPER_TAG:-b5454}"
WHISPER_SHA256="${WHISPER_SHA256:-e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b}"
URL="https://github.com/ggml-org/whisper.cpp/releases/download/$WHISPER_TAG/whisper-$WHISPER_TAG-xcframework.zip"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$REPO/Vendor/whisper.xcframework"
STAMP="$DEST/.tag"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$WHISPER_TAG" ]]; then
  echo "whisper.xcframework $WHISPER_TAG already present"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "Downloading $URL"
curl -fsSL --retry 3 -o "$WORK/whisper.zip" "$URL"
echo "$WHISPER_SHA256  $WORK/whisper.zip" | shasum -a 256 -c -
unzip -q "$WORK/whisper.zip" -d "$WORK/unzipped"
FOUND="$(find "$WORK/unzipped" -name whisper.xcframework -type d | head -1)"
[[ -n "$FOUND" ]] || { echo "whisper.xcframework not found in archive" >&2; exit 1; }
rm -rf "$DEST"
mkdir -p "$REPO/Vendor"
mv "$FOUND" "$DEST"
echo "$WHISPER_TAG" > "$STAMP"
echo "Installed $DEST"
