#!/usr/bin/env bash
# Compiles the real AudioRecorder against scripted audio engines (no microphone needed) and runs a recording
# through device changes: the engine must restart in place and a bounded number of times, never be rebuilt in a
# loop (the 0.0.23 Fn-hold regression). Runs in CI and before a release is built.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
swiftc -O -o "$OUT/recorder-tests" Tests/RecorderTests/main.swift \
  LocalFlow/Capture/AudioRecorder.swift LocalFlow/Capture/AudioInputDevice.swift LocalFlow/Core/AutoGain.swift
"$OUT/recorder-tests"
