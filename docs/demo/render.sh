#!/usr/bin/env bash
# Render the demo mockups in docs/demo/*.html to docs/images/*.png (2x) with headless Chrome.
# Usage: bash docs/demo/render.sh
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../images"; mkdir -p "$out"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
profile="$(mktemp -d "${TMPDIR:-/tmp}/nudge-render.XXXXXX")"
trap 'case "$profile" in */nudge-render.*) rm -rf "$profile" ;; esac' EXIT

render() { # name width height
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --no-first-run \
    --user-data-dir="$profile" --force-device-scale-factor=2 \
    --window-size="$2,$3" --screenshot="$out/$1.png" "file://$here/$1.html" >/dev/null 2>&1
  echo "rendered docs/images/$1.png"
}
render hero      1200 675
render messages  1200 600
render platforms 1200 520
