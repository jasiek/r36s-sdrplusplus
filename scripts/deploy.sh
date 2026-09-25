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
#
# "Deploy" here means a launchable install, not just a file copy: it also puts
# the Westonpack runtime in place, because the port cannot start without it and
# PortMaster's own fetch for it is not something we can rely on (see
# ensure_runtime below).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
ACTION="${1:-deploy}"

DEVICE="${DEVICE:?set DEVICE=user@host, e.g. DEVICE=ark@192.168.1.50}"

# Defines SSH_OPTS (with connection multiplexing), sshd() and ssh_shutdown().
# shellcheck source=scripts/ssh-common.sh
. "$HERE/ssh-common.sh"
trap ssh_shutdown EXIT

# Pinned fallback for the runtime SDR++.sh mounts. resolve_runtime() prefers
# whatever the device's own PortMaster says, so this only has to be right for a
# device whose runtimes.json is missing entirely.
WESTON_RUNTIME="${WESTON_RUNTIME:-weston_pkg_0.2}"
WESTON_URL="${WESTON_URL:-https://github.com/PortsMaster/PortMaster-New/releases/download/2025-07-24_0745/weston_pkg_0.2.squashfs}"
WESTON_MD5="${WESTON_MD5:-0a761c28877625861d9c9c4326664428}"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! \033[0m%s\n' "$*"; }

# Ports live in /roms/ports on most setups but /roms2/ports when the second SD
# card holds the games, which is the common R36S arrangement.
find_ports_dir() {
    sshd 'for d in /roms2/ports /roms/ports; do [ -d "$d" ] && echo "$d" && break; done'
}

# Same search order the launcher uses, so we install the runtime into the same
# PortMaster the launcher will look in.
find_control_dir() {
    sshd 'for d in /opt/system/Tools/PortMaster /opt/tools/PortMaster \
                   "${XDG_DATA_HOME:-$HOME/.local/share}/PortMaster" \
                   /roms2/ports/PortMaster /roms/ports/PortMaster; do
              [ -d "$d" ] && echo "$d" && break
          done'
}

PORTS_DIR="$(find_ports_dir)"
[ -n "$PORTS_DIR" ] || { echo "no ports directory found on $DEVICE"; exit 1; }
GAMEDIR="$PORTS_DIR/sdrpp"

# --------------------------------------------------------------- runtime
# SDR++ renders through Westonpack. PortMaster normally downloads that runtime
# on first launch, via harbourmaster - and harbourmaster is the first thing to
# rot on an ageing install. When it breaks, the runtime never arrives and the
# port dies at the mount with nothing in the log but
#
#   mount: special device .../weston_pkg_0.2.squashfs does not exist
#
# which says nothing about the actual cause. Rather than depend on that path,
# put the runtime there ourselves and verify it.

remote_md5() {
    sshd "md5sum '$1' 2>/dev/null | cut -d' ' -f1" || true
}

host_md5() {
    [ -f "$1" ] || return 0
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | cut -d' ' -f1
    else
        md5 -q "$1"   # BSD/macOS
    fi
}

# Ask the device's PortMaster where the runtime lives, so this keeps working if
# the upstream release ever moves. Keys in runtimes.json are sorted, so within
# each arch block "md5" is the line just before "url" - take the last md5 seen
# before the url we want.
resolve_runtime() {
    local json found md5 url
    json="$(sshd "cat '$CONTROL_DIR/config/runtimes.json' 2>/dev/null" || true)"
    [ -n "$json" ] || return 0

    found="$(printf '%s\n' "$json" | awk -v rt="$WESTON_RUNTIME.squashfs" '
        $0 ~ /"md5": "[0-9a-f]+"/                  { md5 = $0 }
        $0 ~ ("\"url\": \".*/" rt "\"")            { print md5; print $0; exit }
    ' | sed -e 's/^[^:]*: *"//' -e 's/",\{0,1\}$//')"

    md5="$(printf '%s\n' "$found" | sed -n 1p)"
    url="$(printf '%s\n' "$found" | sed -n 2p)"

    case "$md5" in [0-9a-f][0-9a-f]*) ;; *) return 0 ;; esac
    case "$url" in http*) ;; *) return 0 ;; esac

    WESTON_MD5="$md5"
    WESTON_URL="$url"
}

ensure_runtime() {
    local libs="$CONTROL_DIR/libs"
    local target="$libs/$WESTON_RUNTIME.squashfs"
    local stage="/tmp/$WESTON_RUNTIME.squashfs.part"
    local esudo="" cached

    # Most firmwares mount the tools directory world-writable (it is usually
    # exFAT on the same card as the roms), but not all - don't guess.
    sshd "mkdir -p '$libs' 2>/dev/null && [ -w '$libs' ]" || esudo="sudo"

    if [ "$(remote_md5 "$target")" = "$WESTON_MD5" ]; then
        log "Runtime $WESTON_RUNTIME present and verified"
        return
    fi
    if sshd "[ -f '$target' ]"; then
        # A half-finished download is worse than no download: the port gets
        # past its own "runtime missing" check and dies in mount(8) instead.
        warn "runtime $WESTON_RUNTIME is present but does not match the expected md5, replacing it"
    fi

    log "Installing $WESTON_RUNTIME runtime into $libs"
    sshd "rm -f '$stage'"

    if sshd "command -v curl >/dev/null 2>&1 && curl -fsSL --connect-timeout 15 -o '$stage' '$WESTON_URL'" \
    || sshd "command -v wget >/dev/null 2>&1 && wget -q -T 15 -O '$stage' '$WESTON_URL'"; then
        log "  fetched on the device"
    else
        # No network on the handheld is the normal case, not the exception: the
        # R36S has no built-in WiFi and its one USB-C port is usually holding
        # the SDR. Fetch on the host and push it down the link we already have.
        log "  device has no route to it, downloading here instead"
        mkdir -p "$ROOT/work/runtimes"
        cached="$ROOT/work/runtimes/$WESTON_RUNTIME.squashfs"
        if [ "$(host_md5 "$cached")" != "$WESTON_MD5" ]; then
            curl -fL --progress-bar -o "$cached.part" "$WESTON_URL"
            mv "$cached.part" "$cached"
        fi
        # shellcheck disable=SC2086
        scp $SSH_OPTS "$cached" "$DEVICE:$stage"
    fi

    local got
    got="$(remote_md5 "$stage")"
    if [ -z "$got" ]; then
        warn "no md5sum on the device - installing $WESTON_RUNTIME unverified"
    elif [ "$got" != "$WESTON_MD5" ]; then
        sshd "rm -f '$stage'"
        echo "runtime download is corrupt: got $got, expected $WESTON_MD5"
        exit 1
    fi

    sshd "$esudo mv '$stage' '$target' && $esudo chmod 644 '$target'"
    log "  installed $target"
}

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

    # A PortMaster install leaves port.json and gameinfo.xml inside the port
    # folder - that is where EmulationStation finds the cover art and the
    # description. In the zip they sit at the root, so rsyncing dist/sdrpp/
    # alone does not place them. Copy them after the rsync, not before: the
    # --delete above would otherwise remove them again.
    for meta in port.json gameinfo.xml; do
        if [ -f "$ROOT/dist/$meta" ]; then
            # shellcheck disable=SC2086
            scp -q $SSH_OPTS "$ROOT/dist/$meta" "$DEVICE:$GAMEDIR/$meta"
        fi
    done

    sshd "chmod +x '$GAMEDIR/sdrpp.aarch64'"

    CONTROL_DIR="$(find_control_dir)"
    if [ -n "$CONTROL_DIR" ]; then
        resolve_runtime
        ensure_runtime
    else
        warn "no PortMaster directory found on $DEVICE - skipping the runtime;"
        warn "the port will not start without ${WESTON_RUNTIME}.squashfs in PortMaster/libs/"
    fi

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
