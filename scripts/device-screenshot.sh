#!/usr/bin/env bash
# Captures what is actually on the handheld's panel while SDR++ is running.
#
#   make device-screenshot DEVICE=ark@192.168.1.50
#
# PortMaster's submission rules ask for a capture taken on the handheld, rather
# than the host render `make screenshot` produces under Xvfb - a real render at
# the real resolution, but not the device's own panel and without whatever
# letterboxing that panel adds. Read the next paragraph before reaching for
# this, though: on the hardware this port targets, it cannot deliver that.
#
# The port has to be running to have anything to capture, so this launches it,
# waits for the application to report itself ready, grabs a frame and then
# tears the whole thing down again. That teardown is not optional: westonwrap
# holds DRM master, and killing the launcher without running its cleanup leaves
# the display wedged with no way back in over SSH.
#
# KNOWN NOT TO WORK on RK3326 handhelds running a 4.4 vendor kernel, which is
# what an R36S on ArkOS/dArkOS is. Both capture paths below were tried there
# and both fail, for reasons that are properties of the kernel rather than
# anything this script can route around:
#
#   /dev/fb0   is DRM's fbdev emulation, not the scanout buffer. It reports
#              smem_start 0x0 and reads back as 1228800 zero bytes while the
#              VOP's active window is quite happily scanning out a different
#              address (/sys/kernel/debug/dri/0/summary shows both). Nothing is
#              ever blitted into it, because fbcon does not own the CRTC once
#              EmulationStation or crusty has set a framebuffer of its own.
#
#   kmsgrab    finds the active plane and then fails with "Failed to get
#              framebuffer NN: Invalid argument". The buffer belongs to crusty,
#              which holds DRM master, and 4.4 predates drmModeGetFB2 - so
#              there is no way to get a handle to somebody else's framebuffer.
#
# /dev/mem is refused as well (CONFIG_STRICT_DEVMEM), and the firmware ships no
# screenshot tool of its own. On that hardware the only capture left is a photo
# of the handheld. This script is still here because the fbdev path does work
# on devices whose firmware leaves fbcon on the CRTC, and because the next
# person to try deserves the list of dead ends rather than a blank page.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

DEVICE="${DEVICE:?set DEVICE=user@host, e.g. DEVICE=ark@192.168.1.50}"
OUT="${1:-$ROOT/port/screenshot.png}"

# Defines SSH_OPTS (with connection multiplexing), sshd() and ssh_shutdown().
# shellcheck source=scripts/ssh-common.sh
. "$HERE/ssh-common.sh"

# How long to let SDR++ settle before grabbing. It reports "Ready." before the
# first frame is on screen, so this is deliberately a little generous.
SETTLE="${SETTLE:-6}"
READY_TIMEOUT="${READY_TIMEOUT:-90}"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! \033[0m%s\n' "$*"; }

PORTS_DIR="$(sshd 'for d in /roms2/ports /roms/ports; do [ -d "$d" ] && echo "$d" && break; done')"
[ -n "$PORTS_DIR" ] || { echo "no ports directory found on $DEVICE"; exit 1; }
GAMEDIR="$PORTS_DIR/sdrpp"

sshd "[ -f '$PORTS_DIR/SDR++.sh' ]" \
    || { echo "SDR++ is not installed on $DEVICE - run 'make deploy DEVICE=$DEVICE' first"; exit 1; }

# --------------------------------------------------------------- teardown
# Registered before anything is started, so an interrupted run still cleans up.
teardown() {
    log "Stopping SDR++"
    sshd '
        pkill -f sdrpp.aarch64 2>/dev/null
        pkill -f "gptokeyb"     2>/dev/null
        [ -x /tmp/weston/westonwrap.sh ] && sudo /tmp/weston/westonwrap.sh cleanup >/dev/null 2>&1
        sudo umount /tmp/weston 2>/dev/null
        true
    ' >/dev/null 2>&1 || true
    ssh_shutdown
}
trap teardown EXIT

# --------------------------------------------------------------- launch
log "Launching SDR++ on $DEVICE"
sshd "rm -f '$GAMEDIR/log.txt'; cd '$PORTS_DIR' && setsid nohup ./SDR++.sh </dev/null >/tmp/sdrpp-shot.out 2>&1 & true" \
    >/dev/null 2>&1 || true

log "Waiting for it to come up (up to ${READY_TIMEOUT}s)"
deadline=$(( $(date +%s) + READY_TIMEOUT ))
until sshd "grep -aq 'Ready\.' '$GAMEDIR/log.txt' 2>/dev/null"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "SDR++ never reported itself ready - see 'make logs DEVICE=$DEVICE'"
        exit 1
    fi
    sleep 2
done
log "  up; letting it settle for ${SETTLE}s"
sleep "$SETTLE"

# --------------------------------------------------------------- capture
# Two ways in, tried in order. Which one works depends on how the firmware's
# DRM driver is wired: the framebuffer console is the cheap path and is enough
# on kernels whose fbdev emulation shares memory with the scanout buffer;
# kmsgrab reads the active plane directly and is the fallback for the rest.
log "Capturing the panel"
sshd 'cat > /tmp/grabfb.py' <<'PY'
import sys
from PIL import Image

def sysfs(name, default=None):
    try:
        return open("/sys/class/graphics/fb0/" + name).read().strip()
    except OSError:
        return default

w, h = (int(v) for v in sysfs("virtual_size", "640,480").split(","))
bpp   = int(sysfs("bits_per_pixel", "32"))
stride = int(sysfs("stride", str(w * bpp // 8)))

if bpp != 32:
    sys.exit("fb0 is %d bpp, expected 32" % bpp)

with open("/dev/fb0", "rb") as fh:
    raw = fh.read(stride * h)
if len(raw) < stride * h:
    sys.exit("short read from /dev/fb0")

img = Image.frombytes("RGBA", (w, h), raw, "raw", "BGRA", stride).convert("RGB")

# A stale or unused fbdev reads back as a single flat colour. That is not a
# screenshot, it is the absence of one - say so rather than shipping it.
if len(img.getcolors(maxcolors=16) or [1]) < 2:
    sys.exit("framebuffer is a single flat colour - fbdev is not the scanout buffer")

img.save("/tmp/sdrpp-shot.png")
print("%dx%d" % (w, h))
PY

method=""
if size=$(sshd 'sudo python3 /tmp/grabfb.py 2>&1'); then
    method="fbdev"
    log "  captured via /dev/fb0 ($size)"
else
    warn "/dev/fb0: $size"
    if sshd 'sudo ffmpeg -hide_banner -loglevel error -f kmsgrab -i - -frames:v 1 \
                 -vf "hwdownload,format=bgr0" -y /tmp/sdrpp-shot.png' 2>/dev/null; then
        method="kmsgrab"
        log "  captured via kmsgrab"
    else
        echo "could not capture the panel by either method."
        echo "The frame lives in a DRM plane this kernel will not hand back; take"
        echo "a photo of the handheld instead, or capture from HDMI if the unit has it."
        exit 1
    fi
fi

mkdir -p "$(dirname "$OUT")"
# shellcheck disable=SC2086
scp -q $SSH_OPTS "$DEVICE:/tmp/sdrpp-shot.png" "$OUT"
sshd 'rm -f /tmp/grabfb.py /tmp/sdrpp-shot.png' >/dev/null 2>&1 || true

log "Saved $OUT (via $method)"
