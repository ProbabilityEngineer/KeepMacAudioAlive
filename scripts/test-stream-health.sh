#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
xcrun swiftc -parse-as-library -D LIFECYCLE_TESTS \
    -import-objc-header KeepMacAudioAlive/Heartbeat.h \
    KeepMacAudioAlive/KeepAudioAliveApp.swift tests/StreamHealthTests.swift \
    -o "$temporary/stream-health-tests"
"$temporary/stream-health-tests"
