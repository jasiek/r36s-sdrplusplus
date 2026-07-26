#!/usr/bin/env bash
# Copies every shared library SDR++ needs into libs.aarch64/ and rewrites
# RUNPATHs so the port is relocatable. Runs INSIDE the builder container.
#
# What we deliberately do NOT bundle:
#   * glibc core        - must match the running kernel/loader, always the device's
#   * X11 / Wayland     - Westonpack ships these in $weston_dir/lib_aarch64
#   * GL / EGL / GLES / GBM / DRM - Westonpack's chosen gl_library provides them;
#                         shadowing them is the classic way to get a black screen
#   * ALSA              - libasound pulls in device-specific plugin config
set -euo pipefail

STAGE="${1:?usage: bundle-libs.sh <stage-dir>}"
LIBDIR="$STAGE/libs.aarch64"
mkdir -p "$LIBDIR"

# Regexes matched against the SONAME.
EXCLUDE='^(ld-linux-aarch64|libc|libm|libdl|libpthread|librt|libresolv|libnsl|libutil|libcrypt|libanl|linux-vdso)\.so'
EXCLUDE+='|^lib(GL|GLX|GLdispatch|OpenGL|EGL|GLESv1_CM|GLESv2|glapi|gbm|drm)\.so'
EXCLUDE+='|^lib(X11|X11-xcb|Xext|Xrandr|Xinerama|Xcursor|Xi|Xxf86vm|Xrender|Xfixes|Xau|Xdmcp|xcb.*|xshmfence)\.so'
EXCLUDE+='|^libwayland-.*\.so'
EXCLUDE+='|^libasound\.so'
# libstdc++ / libgcc: every CFW ships its own, and PortMaster's guidance is
# explicit that bundling them causes device-specific segfaults that will not
# reproduce in your own testing. We build against focal's gcc 9, which is the
# oldest toolchain any supported firmware uses, so the device copy is always
# new enough. Same reasoning for SDL2, which we do not link at all.
EXCLUDE+='|^lib(stdc\+\+|gcc_s|SDL2.*)\.so'

log() { printf '\033[1;36m  ->\033[0m %s\n' "$*"; }

# Walk the dependency graph breadth-first from the binary and every module.
# ldd prints two shapes we care about:
#   "\tlibfoo.so.1 => /usr/lib/libfoo.so.1 (0x...)"   -> soname, path
#   "\t/lib/ld-linux-aarch64.so.1 (0x...)"            -> path only, so derive
#                                                        the soname from it
# (linux-vdso has neither a path nor a file and falls through both.)
resolve() {
    local obj="$1"
    ldd "$obj" 2>/dev/null | awk '
        /=> \//              { print $1 "\t" $3; next }
        /^[[:space:]]*\/.* \(0x/ { p = $1; n = p; sub(/.*\//, "", n); print n "\t" p }
    '
}

queue=("$STAGE/sdrpp.aarch64" "$STAGE/libs.aarch64/libsdrpp_core.so")
while IFS= read -r m; do queue+=("$m"); done < <(find "$STAGE/modules" -name '*.so')

declare -A seen=()
while [ ${#queue[@]} -gt 0 ]; do
    obj="${queue[0]}"; queue=("${queue[@]:1}")
    [ -f "$obj" ] || continue
    while IFS=$'\t' read -r soname path; do
        [ -n "$soname" ] && [ -n "$path" ] || continue
        [[ "$soname" =~ $EXCLUDE ]] && continue
        [ -n "${seen[$soname]:-}" ] && continue
        seen[$soname]=1
        # Don't re-copy things we built ourselves.
        if [ ! -e "$LIBDIR/$soname" ]; then
            cp -L "$path" "$LIBDIR/$soname"
            chmod 644 "$LIBDIR/$soname"
            log "bundled $soname"
        fi
        queue+=("$LIBDIR/$soname")
    done < <(resolve "$obj")
done

# ------------------------------------------------------------------- runpaths
# RUNPATH (not RPATH) so LD_LIBRARY_PATH / WRAPPED_LIBRARY_PATH from the
# launcher still wins - that is the escape hatch when a device needs its own
# copy of something we shipped.
patchelf --set-rpath '$ORIGIN/libs.aarch64' "$STAGE/sdrpp.aarch64"
for so in "$LIBDIR"/*.so*; do
    patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
done
for so in "$STAGE/modules"/*.so; do
    patchelf --set-rpath '$ORIGIN/../libs.aarch64' "$so"
done

# ------------------------------------------------------------------- licences
# One flat licenses/ directory, one LICENSE.<component>.txt per bundled
# component - the naming PortMaster expects.
for so in "$LIBDIR"/*.so*; do
    component="$(basename "$so" | sed 's/\.so.*$//')"
    [ -f "$STAGE/licenses/LICENSE.${component}.txt" ] && continue
    src="$(readlink -f "$so")"
    pkg="$(dpkg -S "$(basename "$src")" 2>/dev/null | head -1 | cut -d: -f1 || true)"
    if [ -n "$pkg" ] && [ -f "/usr/share/doc/$pkg/copyright" ]; then
        cp "/usr/share/doc/$pkg/copyright" "$STAGE/licenses/LICENSE.${component}.txt"
    fi
done

echo
log "bundled $(find "$LIBDIR" -name '*.so*' | wc -l) libraries ($(du -sh "$LIBDIR" | cut -f1))"

# Fail loudly if anything is still unresolved - much better to find out here
# than as a silent "port does nothing" on the device.
missing=0
for obj in "$STAGE/sdrpp.aarch64" "$LIBDIR"/*.so* "$STAGE/modules"/*.so; do
    while IFS= read -r line; do
        soname="${line%% *}"
        [[ "$soname" =~ $EXCLUDE ]] && continue
        echo "MISSING: $soname (needed by $(basename "$obj"))"
        missing=1
    done < <(ldd "$obj" 2>/dev/null | grep 'not found' || true)
done
[ "$missing" -eq 0 ] || { echo "unresolved dependencies, aborting"; exit 1; }

# The device side of the GL stack is libGL.so.1 and only libGL.so.1. If CMake
# picked up libglvnd instead we would ship a binary whose NEEDED entries no
# handheld can satisfy - and it would still smoke-test green here, because the
# builder does have glvnd. Catch it at build time.
if readelf -d "$STAGE/sdrpp.aarch64" "$LIBDIR"/*.so* "$STAGE/modules"/*.so 2>/dev/null \
     | grep -qE 'NEEDED.*\[lib(OpenGL|GLX|GLdispatch)\.so'; then
    echo "ERROR: linked against libglvnd (libOpenGL/libGLX)."
    echo "       These handhelds only provide libGL.so.1."
    echo "       Build with -DOpenGL_GL_PREFERENCE=LEGACY."
    exit 1
fi
