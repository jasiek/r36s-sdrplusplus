#!/usr/bin/env bash
# Captures SDR++ running at device resolution under Xvfb.
#
# IMPORTANT: this is a HOST capture, not a device capture. It is a real render
# of the real binary at 640x480, which makes it a usable placeholder for the
# self-hosted source listing - but PortMaster's submission rules require a
# screenshot taken on the handheld itself, including any letterboxing, and this
# does not satisfy that. Replace it with a device capture before submitting
# upstream. See README.
#
# Runs INSIDE the builder container.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
STAGE="$ROOT/build/sdrpp"
OUT="${OUT:-$ROOT/port/screenshot.png}"
WIDTH="${WIDTH:-640}"
HEIGHT="${HEIGHT:-480}"
SETTLE="${SETTLE:-20}"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

[ -x "$STAGE/sdrpp.aarch64" ] || { echo "no staged build - run 'make build' first"; exit 1; }

MENU_W="${MENU_W:-$((WIDTH * 34 / 100))}"
UI_SCALE="${UI_SCALE:-}"

CONF="$(mktemp -d)"
sed -e "s/@WIDTH@/$WIDTH/" -e "s/@HEIGHT@/$HEIGHT/" \
    -e "s/@MENU_WIDTH@/$MENU_W/" \
    -e "s/@FFT_HEIGHT@/$((HEIGHT * 28 / 100))/" \
    -e "s|@GAMEDIR@|$STAGE|g" \
    "$ROOT/port/sdrpp/conf-default/config.json" > "$CONF/config.json"

# Lets us sweep layout settings without editing the shipped template.
[ -n "$UI_SCALE" ] && sed -i "s/\"uiScale\": [0-9.]*/\"uiScale\": $UI_SCALE/" "$CONF/config.json"

log "Starting Xvfb at ${WIDTH}x${HEIGHT}"
Xvfb :98 -screen 0 "${WIDTH}x${HEIGHT}x24" >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill $XVFB_PID 2>/dev/null || true' EXIT
sleep 2

cd "$STAGE"
env DISPLAY=:98 LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe HOME="$CONF" \
    ./sdrpp.aarch64 -r "$CONF" >/dev/null 2>&1 &
APP_PID=$!

log "Letting the UI settle (${SETTLE}s)"
sleep "$SETTLE"

kill -0 "$APP_PID" 2>/dev/null || { echo "SDR++ exited before we could capture it"; exit 1; }

log "Capturing"
DISPLAY=:98 import -window root -quality 95 "$OUT"

kill -TERM "$APP_PID" 2>/dev/null || true
sleep 2
kill -KILL "$APP_PID" 2>/dev/null || true

# PortMaster wants 4:3, at least 640x480.
dims="$(identify -format '%wx%h' "$OUT")"
[ "$dims" = "${WIDTH}x${HEIGHT}" ] || { echo "unexpected capture size $dims"; exit 1; }

log "Wrote $OUT ($dims, $(du -h "$OUT" | cut -f1))"
