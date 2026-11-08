#!/bin/bash
# take.sh <name>: records takes/<name>.json in the DemoDriver window and prints the new project as JSON.
# Start the driver first (see README). takes/<name>.pre.json, if present, runs before recording starts.
set -uo pipefail
S=$(cd "$(dirname "$0")" && pwd)
CTL=${DEMO_CTL:-$S/build/ctl}
WID=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['windowId'])" "$CTL/geometry.json")

run() {
  rm -f "$CTL/status"; echo "$1" > "$CTL/cmd"
  for _ in $(seq 1 480); do
    s=$(cat "$CTL/status" 2>/dev/null)
    [ "$s" = "done" ] && return 0
    case "$s" in error*) echo "$s" >&2; return 1;; esac
    sleep 0.25
  done
  echo "take timed out" >&2; return 1
}

[ -f "$S/takes/$1.pre.json" ] && run "$S/takes/$1.pre.json"
python3 "$S/mcp.py" "{\"tool\":\"start_recording\",\"args\":{\"target\":{\"type\":\"window\",\"windowId\":$WID},\"cameraId\":null,\"microphoneId\":null,\"systemAudio\":false,\"countdownSeconds\":0}}" > /dev/null
sleep 1.2
run "$S/takes/$1.json"
sleep 0.6
python3 "$S/mcp.py" '{"tool":"control_recording","args":{"action":"stop"}}' | tail -1
