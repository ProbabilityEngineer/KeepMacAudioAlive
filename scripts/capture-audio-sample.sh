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

destination="$HOME/Downloads/KeepMacAudioAlive-diagnostics/$(date '+%Y%m%d-%H%M%S')-$$"
mkdir -p "$destination"
echo "Sampling PID $pid for 5 seconds; output: $destination"
/usr/bin/sample "$pid" 5 -file "$destination/process-sample.txt"

# Sandboxed builds use the container home; unsigned development builds may not.
for root in \
    "$HOME/Library/Containers/com.github.openmac.KeepAudioAlive/Data/Library/Logs/KeepMacAudioAlive" \
    "$HOME/Library/Logs/KeepMacAudioAlive"; do
    if [[ -d "$root" ]]; then
        label="unsandboxed"
        [[ "$root" == *"/Containers/"* ]] && label="sandboxed"
        mkdir -p "$destination/$label"
        for file in "$root"/lifecycle*.log; do
            [[ -f "$file" ]] && cp "$file" "$destination/$label/"
        done
    fi
done
echo "Saved sample and available lifecycle logs to $destination"
