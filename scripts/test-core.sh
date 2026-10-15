#!/usr/bin/env bash
# Compiles the pure-Foundation core (cleanup, dictionary, env-key scan, version) with swiftc and runs the asserts.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
swiftc -O -o "$OUT/core-tests" Tests/CoreTests/main.swift LocalFlow/Core/*.swift
"$OUT/core-tests"
rm -rf "$OUT"
