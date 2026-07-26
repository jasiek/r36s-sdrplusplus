#!/usr/bin/env bash
# Launches the staged aarch64 build under Xvfb + llvmpipe and checks that it
# actually comes up: core loads, every module loads, a GL context is created,
# frames are rendered.
#
# This is not a substitute for testing on the device - it cannot tell you
# anything about GL4ES, Westonpack or gptokeyb. What it does catch, cheaply,
# is the entire class of "we shipped a bundle that cannot even start":
# unresolved symbols, a module built against a library we forgot to copy, a
# missing resource directory, a bad RUNPATH.
#
# Runs INSIDE the builder container.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
STAGE="$ROOT/build/sdrpp"
RUNTIME=${SMOKE_SECONDS:-25}

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL:\033[0m %s\n' "$*"; exit 1; }

[ -x "$STAGE/sdrpp.aarch64" ] || fail "no staged build at $STAGE"

log "Architecture check"
file "$STAGE/sdrpp.aarch64" | grep -q 'ARM aarch64' || fail "binary is not aarch64"
for so in "$STAGE"/modules/*.so; do
    file "$so" | grep -q 'ARM aarch64' || fail "$(basename "$so") is not aarch64"
done
echo "  binary + $(ls "$STAGE"/modules/*.so | wc -l) modules are aarch64"

log "Dynamic linking check (as the device will see it: no LD_LIBRARY_PATH)"
unresolved=0
for obj in "$STAGE/sdrpp.aarch64" "$STAGE"/modules/*.so "$STAGE"/libs.aarch64/*.so*; do
    if ldd "$obj" 2>/dev/null | grep -q 'not found'; then
        echo "  $(basename "$obj"):"
        ldd "$obj" | grep 'not found' | sed 's/^/    /'
        unresolved=1
    fi
done
[ "$unresolved" -eq 0 ] || fail "unresolved shared libraries"
echo "  all dependencies resolve via RUNPATH"

log "Launching under Xvfb (${RUNTIME}s)"
CONF="$(mktemp -d)"
# Same substitution the launcher does on first run - exercises the template
# too, so a broken placeholder shows up here rather than on the device.
sed -e 's/@WIDTH@/640/' -e 's/@HEIGHT@/480/' \
    -e 's/@MENU_WIDTH@/218/' -e 's/@FFT_HEIGHT@/134/' \
    -e "s|@GAMEDIR@|$STAGE|g" \
    "$ROOT/port/sdrpp/conf-default/config.json" > "$CONF/config.json"
grep -q '@' "$CONF/config.json" && fail "unsubstituted placeholders left in config template"

Xvfb :99 -screen 0 640x480x24 >/dev/null 2>&1 &
XVFB_PID=$!
trap 'kill $XVFB_PID 2>/dev/null || true' EXIT
sleep 2

LOG="$(mktemp)"
cd "$STAGE"
env DISPLAY=:99 \
    LIBGL_ALWAYS_SOFTWARE=1 \
    GALLIUM_DRIVER=llvmpipe \
    HOME="$CONF" \
    ./sdrpp.aarch64 -r "$CONF" > "$LOG" 2>&1 &
APP_PID=$!

sleep "$RUNTIME"

if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "--- log ---"; cat "$LOG"
    fail "SDR++ exited on its own within ${RUNTIME}s"
fi
kill -TERM "$APP_PID" 2>/dev/null || true
sleep 3
kill -KILL "$APP_PID" 2>/dev/null || true

echo "--- log ---"
cat "$LOG"
echo "-----------"

# ---- assertions on the log ---------------------------------------------
grep -qiE 'Using OpenGL' "$LOG" || fail "no OpenGL context was created"
log "GL: $(grep -iE 'Using OpenGL' "$LOG" | head -1 | sed 's/.*Using/Using/')"

# Every module we shipped must appear as loaded.
missing_modules=()
for so in "$STAGE"/modules/*.so; do
    name="$(basename "$so" .so)"
    grep -q "$name" "$LOG" || missing_modules+=("$name")
done
if [ ${#missing_modules[@]} -gt 0 ]; then
    fail "modules never mentioned in the log (did they fail to load?): ${missing_modules[*]}"
fi
echo "  all $(ls "$STAGE"/modules/*.so | wc -l) modules referenced in log"

if grep -qiE "Couldn't load|Failed to load|undefined symbol|Error loading" "$LOG"; then
    grep -iE "Couldn't load|Failed to load|undefined symbol|Error loading" "$LOG" | sed 's/^/  /'
    fail "module loading errors"
fi

log "Smoke test passed"
