#!/bin/sh
# Saves PNGs of tabieum's windows without taking focus. Needs Screen Recording permission.
# Usage: scripts/ui-capture.sh [settings|ai|search|backlinks|toast|action-button|overlays|all] [output-dir] [tab-name]
# The tab name applies to settings only.
set -eu
cd "$(dirname "$0")/.."

target=${1:-settings}
dir=${2:-build/ui-capture}
case "$target" in
settings) filter=captureSettingsTabs prefixes=settings ;;
ai) filter=captureAIPanel prefixes=ai ;;
search) filter=captureSearchPanel prefixes=search ;;
backlinks) filter=captureBacklinksPanel prefixes=backlinks ;;
toast) filter=captureToast prefixes=toast ;;
action-button) filter=captureActionButton prefixes=action-button ;;
overlays) filter=captureOverlays prefixes=overlays ;;
all) filter='UICaptureTests|PanelCaptureTests|OverlayCaptureTests' prefixes='settings ai search backlinks toast action-button overlays' ;;
*)
    echo "unknown target: $target" >&2
    exit 2
    ;;
esac

mkdir -p "$dir"
dir=$(cd "$dir" && pwd)
for prefix in $prefixes; do
    rm -f "$dir/$prefix"-*.png "$dir/$prefix.png"
done

front() {
    osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'
}

before=$(front)
UI_CAPTURE_DIR=$dir UI_CAPTURE_TAB=${3:-} scripts/test.sh --filter "$filter"
after=$(front)

found=
for prefix in $prefixes; do
    for file in "$dir/$prefix"-*.png "$dir/$prefix.png"; do
        [ -e "$file" ] && echo "$file" && found=1
    done
done
[ -n "$found" ] || { echo "no PNGs were written" >&2; exit 1; }
case "$target" in
overlays | all) echo "overlays are drawn on a stand-in editor, not Notes: the Accessibility quirks of Notes itself are not covered" >&2 ;;
esac
[ "$before" = "$after" ] || echo "warning: the front app changed from $before to $after" >&2
