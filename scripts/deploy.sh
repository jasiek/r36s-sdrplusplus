#!/usr/bin/env bash
# Pushes the built port straight to a device over SSH, and pulls its log back.
#
# Reinstalling through PortMaster for every change is far too slow a loop for
# the part of this port that actually needs iterating - the graphics path.
# This copies only what changed and leaves conf/ alone so your settings and
# any first-run state survive.
#
#   make deploy DEVICE=ark@192.168.1.50
#   make logs   DEVICE=ark@192.168.1.50
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
ACTION="${1:-deploy}"

DEVICE="${DEVICE:?set DEVICE=user@host, e.g. DEVICE=ark@192.168.1.50}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ConnectTimeout=10}"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

# shellcheck disable=SC2086
sshd() { ssh $SSH_OPTS "$DEVICE" "$@"; }

# Ports live in /roms/ports on most setups but /roms2/ports when the second SD
# card holds the games, which is the common R36S arrangement.
find_ports_dir() {
    sshd 'for d in /roms2/ports /roms/ports; do [ -d "$d" ] && echo "$d" && break; done'
}

PORTS_DIR="$(find_ports_dir)"
[ -n "$PORTS_DIR" ] || { echo "no ports directory found on $DEVICE"; exit 1; }
GAMEDIR="$PORTS_DIR/sdrpp"

case "$ACTION" in
deploy)
    [ -d "$ROOT/dist/sdrpp" ] || { echo "no dist/ - run 'make package' first"; exit 1; }
    log "Deploying to $DEVICE:$GAMEDIR"

    sshd "mkdir -p '$GAMEDIR'"

    # rsync when the device has it (most CFW do), scp otherwise.
    if sshd 'command -v rsync >/dev/null 2>&1'; then
        # shellcheck disable=SC2086
        rsync -az --delete --exclude 'conf/' --exclude 'log.txt' --exclude 'graphics.cfg' \
            -e "ssh $SSH_OPTS" \
            "$ROOT/dist/sdrpp/" "$DEVICE:$GAMEDIR/"
        # shellcheck disable=SC2086
        rsync -az -e "ssh $SSH_OPTS" "$ROOT/dist/SDR++.sh" "$DEVICE:$PORTS_DIR/"
    else
        log "no rsync on device, falling back to scp (slower, copies everything)"
        # shellcheck disable=SC2086
        scp $SSH_OPTS -r "$ROOT/dist/sdrpp"/* "$DEVICE:$GAMEDIR/"
        # shellcheck disable=SC2086
        scp $SSH_OPTS "$ROOT/dist/SDR++.sh" "$DEVICE:$PORTS_DIR/"
    fi

    sshd "chmod +x '$GAMEDIR/sdrpp.aarch64'"
    log "Done. Launch it from the Ports menu, then: make logs DEVICE=$DEVICE"
    ;;

logs)
    log "Fetching $GAMEDIR/log.txt"
    sshd "cat '$GAMEDIR/log.txt'" > "$ROOT/device-log.txt" \
        || { echo "no log yet - run the port on the device first"; exit 1; }
    echo "  saved to device-log.txt ($(wc -l < "$ROOT/device-log.txt" | tr -d ' ') lines)"
    echo
    tail -40 "$ROOT/device-log.txt"
    ;;

*)
    echo "usage: DEVICE=user@host $0 [deploy|logs]"
    exit 1
    ;;
esac
