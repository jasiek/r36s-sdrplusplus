#!/usr/bin/env bash
# Assembles build/sdrpp (from build.sh) plus port/ into a PortMaster-installable
# zip. Runs on the host - no container needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

STAGE="$ROOT/build/sdrpp"
PORT="$ROOT/port"
DIST="$ROOT/dist"
OUT="$DIST/sdrpp.zip"
PORTER="${PORTER:-Unknown}"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

[ -d "$STAGE" ] || { echo "no build found at $STAGE - run 'make build' first"; exit 1; }

rm -rf "$DIST"
mkdir -p "$DIST/sdrpp"

# --- port folder ---------------------------------------------------------
log "Assembling port folder"
cp -r "$STAGE"/. "$DIST/sdrpp/"
cp -r "$PORT/sdrpp"/. "$DIST/sdrpp/"

# --- launch script + metadata (zip root) ---------------------------------
cp "$PORT/SDR++.sh" "$DIST/SDR++.sh"
sed "s/@PORTER@/$PORTER/g" "$PORT/port.json" > "$DIST/port.json"
cp "$PORT/gameinfo.xml" "$DIST/gameinfo.xml"
cp "$PORT/README.md"    "$DIST/README.md"
for img in screenshot.png screenshot.jpg cover.png; do
    [ -f "$PORT/$img" ] && cp "$PORT/$img" "$DIST/$img"
done
# gameinfo.xml points EmulationStation at ./sdrpp/cover.png, so the cover has
# to exist inside the port folder as well as at the zip root where PortMaster
# looks for it.
[ -f "$PORT/cover.png" ] && cp "$PORT/cover.png" "$DIST/sdrpp/cover.png"

# --- permissions ---------------------------------------------------------
# PortMaster extracts onto FAT32 as often as ext4; the launcher re-chmods the
# binary at runtime, but get the modes right in the archive anyway.
# The .sh stays 644 by PortMaster convention - zip extraction drops exec bits
# anyway, and the launcher self-heals the binary's bit at runtime.
chmod 644 "$DIST/SDR++.sh"
chmod 755 "$DIST/sdrpp/sdrpp.aarch64"
find "$DIST/sdrpp" -name '*.so*' -exec chmod 644 {} +

# --- sanity checks -------------------------------------------------------
# Deliberately shell-only. This script runs on whatever the porter happens to
# have; assuming a working python3 on the host is how you get a packaging step
# that breaks on someone else's machine.
log "Validating"
grep -q '"name": *"sdrpp.zip"' "$DIST/port.json" \
    || { echo "port.json 'name' must match the zip filename"; exit 1; }
grep -q '@PORTER@' "$DIST/port.json" \
    && { echo "porter substitution failed"; exit 1; }
grep -q '"Unknown"' "$DIST/port.json" \
    && echo '  ! porter is "Unknown" - set PORTER="Your Name" before submitting'

# Everything port.json claims to ship must actually be in the zip.
for item in "SDR++.sh" "sdrpp"; do
    grep -q "\"$item\"" "$DIST/port.json" \
        || { echo "port.json does not list $item"; exit 1; }
    [ -e "$DIST/$item" ] || { echo "port.json lists $item but it is missing"; exit 1; }
done
echo "  port.json OK"

# The config template must still be a template - if a substituted copy ever
# leaks in here, first run on device would silently skip seeding.
grep -q '@WIDTH@' "$DIST/sdrpp/conf-default/config.json" \
    || { echo "conf-default/config.json is not a template"; exit 1; }

for required in "$DIST/SDR++.sh" "$DIST/sdrpp/sdrpp.aarch64" "$DIST/sdrpp/libs.aarch64/libsdrpp_core.so" "$DIST/sdrpp/res/fonts" "$DIST/sdrpp/sdrpp.gptk"; do
    [ -e "$required" ] || { echo "MISSING from package: $required"; exit 1; }
done
n_modules=$(find "$DIST/sdrpp/modules" -name '*.so' | wc -l | tr -d ' ')
[ "$n_modules" -gt 0 ] || { echo "no modules were staged"; exit 1; }
log "$n_modules modules, $(find "$DIST/sdrpp/libs.aarch64" -name '*.so*' | wc -l | tr -d ' ') bundled libs"

# --- zip -----------------------------------------------------------------
log "Creating $OUT"
( cd "$DIST" && zip -q -r -X "$(basename "$OUT")" \
    "SDR++.sh" "sdrpp" "port.json" "gameinfo.xml" "README.md" \
    $(cd "$DIST" && ls screenshot.png screenshot.jpg cover.png 2>/dev/null || true) )

log "Done: $OUT ($(du -h "$OUT" | cut -f1))"
unzip -l "$OUT" | tail -5
