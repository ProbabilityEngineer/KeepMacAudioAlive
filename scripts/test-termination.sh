#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
xcrun swiftc -parse-as-library -D LIFECYCLE_TESTS \
    KeepMacAudioAlive/KeepAudioAliveApp.swift tests/TerminationTests.swift \
    -o "$temporary/termination-tests"
"$temporary/termination-tests"
