#!/bin/sh
# Saves a PNG of each Settings tab without taking focus. Needs Screen Recording permission.
# Usage: scripts/ui-capture.sh [output-dir] [tab-name]
set -eu
cd "$(dirname "$0")/.."

dir=${1:-build/ui-capture}
mkdir -p "$dir"
dir=$(cd "$dir" && pwd)
rm -f "$dir"/settings-*.png

front() {
    osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'
}

before=$(front)
UI_CAPTURE_DIR=$dir UI_CAPTURE_TAB=${2:-} scripts/test.sh --filter captureSettingsTabs
after=$(front)

ls "$dir"/settings-*.png
[ "$before" = "$after" ] || echo "warning: the front app changed from $before to $after" >&2
