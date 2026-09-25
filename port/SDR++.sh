#!/bin/bash
# SDR++ for PortMaster
# https://github.com/AlexandreRouma/SDRPlusPlus

# ------------------------------------------------------------ PortMaster preamble
XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}
if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi
source $controlfolder/control.txt
[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"
get_controls

GAMEDIR=/$directory/ports/sdrpp
CONFDIR="$GAMEDIR/conf"

> "$GAMEDIR/log.txt" && exec > >(tee "$GAMEDIR/log.txt") 2>&1

cd "$GAMEDIR"
$ESUDO mkdir -p "$CONFDIR"
$ESUDO chmod 777 "$CONFDIR"
$ESUDO chmod +x "$GAMEDIR/sdrpp.aarch64"

# ------------------------------------------------------------ first-run config
# SDR++ ships desktop defaults (1280x720 window, 65536-point FFT). Neither is
# survivable on a 640x480 / 1GB handheld, so seed a device-appropriate config
# the first time and never touch it again - the user's tweaks stick.
if [ ! -f "$CONFDIR/config.json" ]; then
    echo "First run: installing default config for ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}"

    # Menu gets about a third of the width, waterfall keeps the rest.
    MENU_W=$(( DISPLAY_WIDTH * 34 / 100 ))
    [ "$MENU_W" -lt 180 ] && MENU_W=180
    FFT_H=$(( DISPLAY_HEIGHT * 28 / 100 ))
    [ "$FFT_H" -lt 80 ] && FFT_H=80

    # sed rather than python3: not every firmware ships an interpreter, and a
    # port that dies in its own first-run setup is a miserable thing to debug.
    sed -e "s/@WIDTH@/$DISPLAY_WIDTH/" \
        -e "s/@HEIGHT@/$DISPLAY_HEIGHT/" \
        -e "s/@MENU_WIDTH@/$MENU_W/" \
        -e "s/@FFT_HEIGHT@/$FFT_H/" \
        -e "s|@GAMEDIR@|$GAMEDIR|g" \
        "$GAMEDIR/conf-default/config.json" > "$CONFDIR/config.json"
fi

# Re-point the module and resource directories on every launch. They have to be
# absolute, because westonwrap is under no obligation to preserve our working
# directory - but an absolute path baked in at first run goes stale the moment
# the ports folder moves between /roms and /roms2, which happens whenever
# someone swaps SD cards. Rewriting both keys each time costs nothing and makes
# the port survive being moved.
sed -i -e "s|\"modulesDirectory\": *\"[^\"]*\"|\"modulesDirectory\": \"$GAMEDIR/modules\"|" \
       -e "s|\"resourcesDirectory\": *\"[^\"]*\"|\"resourcesDirectory\": \"$GAMEDIR/res\"|" \
       "$CONFDIR/config.json"

# ------------------------------------------------------------ graphics options
# Overridable without a rebuild: drop a graphics.cfg next to this script with
# e.g.  WESTON_MODE="drm gl kiosk gl4es"   to try a different path.
# Defaults are the combination that works on RK3326-class Mali blob devices
# (ArkOS/muOS): no real compositor, GLX faked over SDL2, GL4ES underneath.
#
# LIBGL_GL=30 is load-bearing and must not be lowered to 21. ImGui's bundled
# gl3w loader hard-fails when GL_MAJOR_VERSION < 3 (imgl3wInit ->
# parse_version -> GL3W_ERROR_OPENGL_VERSION), and it does that *before* the
# GLSL version string matters - so SDR++'s own "fall back to GLSL 1.2" path
# cannot save it and the backend returns -1 (exit 255). GL4ES at 30 still
# renders through the same 2.1-class driver, it just reports 3.0 and turns on
# its VAO emulation, which is exactly what the ImGui GL3 renderer needs.
WESTON_MODE="headless noop kiosk crusty_glx_gl4es"
GL4ES_ENV="LIBGL_ES=2 LIBGL_GL=30 LIBGL_NOHIGHP=1 LIBGL_NOBANNER=1 LIBGL_MIPMAP=3"
[ -f "$GAMEDIR/graphics.cfg" ] && source "$GAMEDIR/graphics.cfg"

# ------------------------------------------------------------ weston runtime
weston_dir=/tmp/weston
weston_runtime="weston_pkg_0.2"
$ESUDO mkdir -p "${weston_dir}"
if [ ! -f "$controlfolder/libs/${weston_runtime}.squashfs" ]; then
  if [ ! -f "$controlfolder/harbourmaster" ]; then
    pm_message "This port requires the latest PortMaster, see https://portmaster.games/"
    sleep 5
    exit 1
  fi
  $ESUDO $controlfolder/harbourmaster --quiet --no-check runtime_check "${weston_runtime}.squashfs"
fi
if [[ "$PM_CAN_MOUNT" != "N" ]]; then
    $ESUDO umount "${weston_dir}" 2>/dev/null
fi
$ESUDO mount "$controlfolder/libs/${weston_runtime}.squashfs" "${weston_dir}"

# ------------------------------------------------------------ controls
# SDR++ has no gamepad support at all - every interaction is mouse or keyboard.
# gptokeyb turns the stick into a pointer; see sdrpp.gptk for the full map.
GPTK="$GAMEDIR/sdrpp.gptk"
[ -f "$GAMEDIR/sdrpp.gptk.$ANALOG_STICKS" ] && GPTK="$GAMEDIR/sdrpp.gptk.$ANALOG_STICKS"

$GPTOKEYB "sdrpp.aarch64" -c "$GPTK" &

# Optional, and genuinely absent on some firmwares: it is defined in
# mod_${CFW_NAME}.txt, and a CFW with no mod file of its own (dArkOSRE, for
# one) never gets it. Calling it unguarded just prints "command not found".
if command -v pm_platform_helper >/dev/null 2>&1; then
  pm_platform_helper "$GAMEDIR/sdrpp.aarch64" >/dev/null
fi

# ------------------------------------------------------------ run
# CRUSTY_SHOW_CURSOR is not optional here: without a visible pointer a
# mouse-driven app is unusable.
$ESUDO env \
    CRUSTY_RESOLUTION=${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} \
    CRUSTY_SHOW_CURSOR=1 \
    $GL4ES_ENV \
    "$weston_dir/westonwrap.sh" $WESTON_MODE \
    HOME="$CONFDIR" \
    XDG_DATA_HOME="$CONFDIR" \
    XDG_CONFIG_HOME="$CONFDIR" \
    "$GAMEDIR/sdrpp.aarch64" -r "$CONFDIR"
# No LD_LIBRARY_PATH on purpose. The binary and modules carry a RUNPATH of
# $ORIGIN/libs.aarch64, which is enough to find everything we ship, and
# Westonpack owns the library path for the GL and X11 stack - setting
# LD_LIBRARY_PATH or WRAPPED_LIBRARY_PATH here would fight it for no gain.

# ------------------------------------------------------------ cleanup
$ESUDO "$weston_dir/westonwrap.sh" cleanup
if [[ "$PM_CAN_MOUNT" != "N" ]]; then
    $ESUDO umount "${weston_dir}" 2>/dev/null
fi
# No pkill for gptokeyb: EmulationStation's process groups already reap it, and
# pm_finish handles the rest. Hand-rolled cleanup here is what PortMaster asks
# porters not to write.
pm_finish
