#!/bin/bash
# Run while recovery is delayed. Does not stop/restart the app or change audio.
set -euo pipefail

pid="${1:-}"
if [[ -z "$pid" ]]; then
    pids="$(pgrep -x KeepMacAudioAlive || true)"
    count="$(printf '%s\n' "$pids" | awk 'NF { n++ } END { print n+0 }')"
    if [[ "$count" != 1 ]]; then
        echo "Expected one KeepMacAudioAlive process; found $count." >&2
        echo "Usage: $0 PID   (find the PID in Activity Monitor)" >&2
        exit 1
    fi
    pid="$pids"
fi
if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    echo "PID must be numeric." >&2
    exit 1
fi

exec python3 "$(dirname "$0")/capture-audio-sample.py" "$pid"
