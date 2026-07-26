#!/usr/bin/env bash
# Builds SDR++ for aarch64 and stages a self-contained tree.
# Runs INSIDE the builder container (see docker/Dockerfile).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

SDRPP_REPO="${SDRPP_REPO:-https://github.com/AlexandreRouma/SDRPlusPlus.git}"
SDRPP_REF="${SDRPP_REF:-master}"

WORK="$ROOT/work"
SRC="$WORK/src"
BUILD="$WORK/build"
INSTALL="$WORK/install"
STAGE="$ROOT/build/sdrpp"          # becomes the on-device port folder
JOBS="${JOBS:-$(nproc)}"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- fetch source
mkdir -p "$WORK"
if [ ! -d "$SRC/.git" ]; then
    log "Cloning SDR++ ($SDRPP_REF)"
    git clone "$SDRPP_REPO" "$SRC"
fi
log "Checking out $SDRPP_REF"
git -C "$SRC" fetch --all --tags --quiet
git -C "$SRC" checkout --quiet "$SDRPP_REF"
git -C "$SRC" submodule update --init --recursive --quiet || true
SDRPP_SHA="$(git -C "$SRC" rev-parse --short HEAD)"
log "SDR++ at $SDRPP_SHA"

# ------------------------------------------------------------------- patches
# Kept as reviewable diffs rather than sed surgery, so they are easy to drop
# when upstream takes them. Reset first: the checkout is reused across builds.
git -C "$SRC" checkout --quiet -- .
if compgen -G "$ROOT/patches/*.patch" > /dev/null; then
    for p in "$ROOT"/patches/*.patch; do
        log "Applying $(basename "$p")"
        git -C "$SRC" apply --verbose "$p" || {
            echo "patch failed - it probably went upstream, check and remove it"
            exit 1
        }
    done
fi

# ------------------------------------------------------------------- configure
# Module set tuned for the R36S: 4x Cortex-A35 @ 1.3GHz, 1GB RAM, 640x480.
# Anything needing a dependency the device will never have, or that costs more
# CPU than this SoC can spare, is off. Override with SDRPP_CMAKE_EXTRA.
CMAKE_OPTS=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX=/usr
    -DOPT_BACKEND_GLFW=ON

    # Link libGL.so.1, not libglvnd's libOpenGL.so.0 + libGLX.so.0.
    # This matters: GL4ES and every vendor blob these handhelds ship provide
    # libGL.so.1 and nothing else, so a glvnd-linked binary has an unsatisfiable
    # NEEDED entry and dies at load time. CMake prefers GLVND by default on any
    # host that has it, which a modern Ubuntu builder does.
    -DOpenGL_GL_PREFERENCE=LEGACY

    # --- sources: kept ---
    -DOPT_BUILD_RTL_SDR_SOURCE=ON
    -DOPT_BUILD_RTL_TCP_SOURCE=ON
    -DOPT_BUILD_AIRSPY_SOURCE=ON
    -DOPT_BUILD_AIRSPYHF_SOURCE=ON
    -DOPT_BUILD_HACKRF_SOURCE=ON
    -DOPT_BUILD_AUDIO_SOURCE=ON
    -DOPT_BUILD_FILE_SOURCE=ON
    -DOPT_BUILD_NETWORK_SOURCE=ON
    -DOPT_BUILD_SPYSERVER_SOURCE=ON
    -DOPT_BUILD_SDRPP_SERVER_SOURCE=ON
    -DOPT_BUILD_RFSPACE_SOURCE=ON
    -DOPT_BUILD_HERMES_SOURCE=ON
    -DOPT_BUILD_SPECTRAN_HTTP_SOURCE=ON

    # --- sources: dropped (missing deps / no chance of being plugged in) ---
    -DOPT_BUILD_PLUTOSDR_SOURCE=OFF
    -DOPT_BUILD_BLADERF_SOURCE=OFF
    -DOPT_BUILD_LIMESDR_SOURCE=OFF
    -DOPT_BUILD_SOAPY_SOURCE=OFF
    -DOPT_BUILD_USRP_SOURCE=OFF
    -DOPT_BUILD_PERSEUS_SOURCE=OFF
    -DOPT_BUILD_FOBOSSDR_SOURCE=OFF
    -DOPT_BUILD_HAROGIC_SOURCE=OFF
    -DOPT_BUILD_BADGESDR_SOURCE=OFF
    -DOPT_BUILD_DRAGONLABS_SOURCE=OFF
    -DOPT_BUILD_HYDRASDR_SOURCE=OFF
    -DOPT_BUILD_KCSDR_SOURCE=OFF
    -DOPT_BUILD_RFNM_SOURCE=OFF
    -DOPT_BUILD_SDRPLAY_SOURCE=OFF
    -DOPT_BUILD_SPECTRAN_SOURCE=OFF

    # --- sinks ---
    -DOPT_BUILD_AUDIO_SINK=ON
    -DOPT_BUILD_NETWORK_SINK=ON
    -DOPT_BUILD_PORTAUDIO_SINK=OFF
    -DOPT_BUILD_NEW_PORTAUDIO_SINK=OFF
    -DOPT_BUILD_ANDROID_AUDIO_SINK=OFF

    # --- decoders ---
    -DOPT_BUILD_RADIO=ON
    -DOPT_BUILD_PAGER_DECODER=ON
    -DOPT_BUILD_ATV_DECODER=OFF
    -DOPT_BUILD_METEOR_DEMODULATOR=OFF
    -DOPT_BUILD_M17_DECODER=OFF
    -DOPT_BUILD_DAB_DECODER=OFF
    -DOPT_BUILD_WEATHER_SAT_DECODER=OFF
    -DOPT_BUILD_FALCON9_DECODER=OFF
    -DOPT_BUILD_KG_SSTV_DECODER=OFF
    -DOPT_BUILD_RYFI_DECODER=OFF
    -DOPT_BUILD_VOR_RECEIVER=OFF

    # --- misc ---
    -DOPT_BUILD_FREQUENCY_MANAGER=ON
    -DOPT_BUILD_RECORDER=ON
    -DOPT_BUILD_SCANNER=ON
    -DOPT_BUILD_RIGCTL_SERVER=ON
    -DOPT_BUILD_RIGCTL_CLIENT=ON
    -DOPT_BUILD_IQ_EXPORTER=ON
    -DOPT_BUILD_DISCORD_PRESENCE=OFF
    -DOPT_BUILD_SCHEDULER=OFF
)
# shellcheck disable=SC2206
[ -n "${SDRPP_CMAKE_EXTRA:-}" ] && CMAKE_OPTS+=(${SDRPP_CMAKE_EXTRA})

log "Configuring"
cmake -S "$SRC" -B "$BUILD" "${CMAKE_OPTS[@]}"

log "Building with $JOBS jobs"
cmake --build "$BUILD" -j"$JOBS"

log "Installing to staging root"
rm -rf "$INSTALL"
DESTDIR="$INSTALL" cmake --install "$BUILD" >/dev/null

# --------------------------------------------------------------------- restage
# `make install` gives us a /usr tree. Flatten it into the layout the port
# uses on device, which has to be relocatable (the ports dir is /roms/ports on
# some CFW and /roms2/ports on others).
log "Staging port tree"
rm -rf "$STAGE"
mkdir -p "$STAGE"/{modules,libs.aarch64,res,licenses,conf-default}

cp "$INSTALL/usr/bin/sdrpp"                "$STAGE/sdrpp.aarch64"
cp "$INSTALL/usr/lib/libsdrpp_core.so"     "$STAGE/libs.aarch64/"
cp "$INSTALL"/usr/lib/sdrpp/plugins/*.so   "$STAGE/modules/"
cp -r "$INSTALL"/usr/share/sdrpp/*         "$STAGE/res/"

chmod 755 "$STAGE/sdrpp.aarch64"

# Licences: ours plus every bundled library's, per PortMaster submission rules.
cp "$SRC/LICENSE" "$STAGE/licenses/LICENSE.sdrpp.txt" 2>/dev/null \
    || cp "$SRC/license" "$STAGE/licenses/LICENSE.sdrpp.txt"

# Licences for anything we built from source rather than installed from apt,
# which dpkg -S in bundle-libs.sh cannot find (currently just RtAudio).
if [ -d /usr/local/share/port-licenses ]; then
    cp /usr/local/share/port-licenses/*.txt "$STAGE/licenses/" 2>/dev/null || true
fi

echo "$SDRPP_SHA" > "$STAGE/sdrpp.version"
git -C "$SRC" log -1 --format="%H%n%ci%n%s" > "$STAGE/sdrpp.buildinfo"

# ---------------------------------------------------------------------- bundle
"$HERE/bundle-libs.sh" "$STAGE"

log "Build complete: $STAGE"
du -sh "$STAGE"
