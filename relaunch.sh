#!/bin/bash
# Build the signed app from this checkout, stop any older NotchApp instance,
# then launch and prove the executable path of the replacement.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/NotchApp.app"
EXECUTABLE="$APP/Contents/MacOS/NotchApp"

"$ROOT/bundle.sh" "$CONFIG"

while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    echo "Stopping NotchApp pid $pid"
    kill -TERM "$pid"
done < <(pgrep -x NotchApp || true)

for _ in {1..50}; do
    if ! pgrep -x NotchApp >/dev/null; then break; fi
    sleep 0.1
done

if pgrep -x NotchApp >/dev/null; then
    echo "NotchApp did not terminate; refusing to launch a second instance." >&2
    exit 1
fi

echo "Launching $APP"
open -n "$APP"

for _ in {1..50}; do
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        command="$(ps -p "$pid" -o command=)"
        if [[ "$command" == "$EXECUTABLE" ]]; then
            echo "Running pid $pid: $command"
            exit 0
        fi
    done < <(pgrep -x NotchApp || true)
    sleep 0.1
done

echo "The expected NotchApp executable did not appear: $EXECUTABLE" >&2
exit 1
