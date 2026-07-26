#!/usr/bin/env bash
# Generates the PortMaster source manifest for self-hosting.
#
# PortMaster's harbourmaster reads third-party repos through one of the APIs in
# HM_SOURCE_APIS. We use PortMasterV2, which points at a GitHub *release* and
# reads its assets - so the zips live on releases rather than being committed
# into git, which is the same arrangement the official repo uses.
#
# Produces, next to the zip:
#   dist/ports.json          -> uploaded as a release asset alongside sdrpp.zip
#   dist/sdrpp.source.json   -> what a user drops into PortMaster/config/
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
DIST="$ROOT/dist"
ZIP="$DIST/sdrpp.zip"

GH_USER="${GH_USER:-jasiek}"
GH_REPO="${GH_REPO:-r36s-sdrplusplus}"
TAG="${TAG:-latest}"
SOURCE_NAME="${SOURCE_NAME:-SDR++ ($GH_USER)}"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

[ -f "$ZIP" ] || { echo "no $ZIP - run 'make package' first"; exit 1; }

# md5sum on Linux, md5 -q on macOS.
if command -v md5sum >/dev/null 2>&1; then
    MD5="$(md5sum "$ZIP" | cut -d' ' -f1)"
else
    MD5="$(md5 -q "$ZIP")"
fi
SIZE="$(wc -c < "$ZIP" | tr -d ' ')"
TODAY="$(date -u +%Y-%m-%d)"

if [ "$TAG" = "latest" ]; then
    DL_URL="https://github.com/$GH_USER/$GH_REPO/releases/latest/download/sdrpp.zip"
else
    DL_URL="https://github.com/$GH_USER/$GH_REPO/releases/download/$TAG/sdrpp.zip"
fi

# ---------------------------------------------------------------- ports.json
# Shape is dictated by PortMasterV2._update(): ports keyed by zip name, each
# carrying md5 / date_added / date_updated / download_url / download_size on
# top of the normal port.json body. `utils` is iterated unconditionally, so it
# has to exist even when empty.
log "Building ports.json (md5 $MD5, ${SIZE} bytes)"

PORT_BODY="$(sed -e '1s/^{//' -e '$s/}$//' "$DIST/port.json")"

cat > "$DIST/ports.json" <<EOF
{
    "ports": {
        "sdrpp.zip": {
$PORT_BODY,
            "md5": "$MD5",
            "date_added": "${DATE_ADDED:-$TODAY}",
            "date_updated": "$TODAY",
            "download_url": "$DL_URL",
            "download_size": $SIZE
        }
    },
    "utils": {}
}
EOF

# ------------------------------------------------------------- source.json
# `version` matches PortMasterV2.VERSION; `last_checked: null` makes the first
# load fetch immediately. The name must not be "PortMaster" or "PortMaster
# Multiverse" - harbourmaster silently rewrites those two to the V3 API.
log "Building sdrpp.source.json"
cat > "$DIST/sdrpp.source.json" <<EOF
{
    "version": 4,
    "prefix": "sdrpp",
    "api": "PortMasterV2",
    "name": "$SOURCE_NAME",
    "url": "https://api.github.com/repos/$GH_USER/$GH_REPO/releases/latest",
    "last_checked": null,
    "data": {}
}
EOF

# ------------------------------------------------------------------ checks
# ports.json is assembled by splicing port.json into a wrapper, so a change to
# port.json's formatting could quietly produce something that parses but is
# missing a key harbourmaster dereferences without guarding. Check for exactly
# the keys PortMasterV2._update() and .download() touch.
PY=""
for c in /usr/bin/python3 python3; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done

if [ -n "$PY" ]; then
    "$PY" - "$DIST/ports.json" "$DIST/sdrpp.source.json" <<'PYEOF'
import json, sys
ports = json.load(open(sys.argv[1]))
assert "utils" in ports, "ports.json needs a 'utils' key (iterated unconditionally)"
entry = ports["ports"]["sdrpp.zip"]
for k in ("md5", "date_added", "date_updated", "download_url", "download_size",
          "version", "name", "items", "attr"):
    assert k in entry, f"ports.json entry missing {k!r}"
assert entry["name"] == "sdrpp.zip"

src = json.load(open(sys.argv[2]))
for k in ("version", "prefix", "api", "name", "last_checked", "data", "url"):
    assert k in src, f"source.json missing {k!r}"
assert src["api"] == "PortMasterV2"
assert src["name"] not in ("PortMaster", "PortMaster Multiverse"), \
    "harbourmaster rewrites those two names to the V3 API"
print("  manifests OK")
PYEOF
else
    echo "  ! no python3 found, skipping manifest validation"
fi

log "Done"
echo "  release assets : dist/sdrpp.zip  dist/ports.json"
echo "  users install  : dist/sdrpp.source.json -> <device>/PortMaster/config/"
echo "  source url     : https://api.github.com/repos/$GH_USER/$GH_REPO/releases/latest"
