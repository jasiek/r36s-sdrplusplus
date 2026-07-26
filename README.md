# SDR++ for PortMaster (R36S and friends)

A reproducible build pipeline that turns upstream
[SDR++](https://github.com/AlexandreRouma/SDRPlusPlus) into a
[PortMaster](https://portmaster.games/)-installable port for RK3326-class Linux
handhelds — the R36S in particular.

```bash
make            # build, smoke test, package -> dist/sdrpp.zip
```

That's the whole thing. Everything below is why it's shaped this way.

---

## The problem

SDR++ is a desktop application. It expects GLFW, a window system, desktop
OpenGL, a mouse and a 1280x720 screen. An R36S has none of those: a 1.3 GHz
quad Cortex-A35, 1 GB of RAM, a 640x480 panel, a Mali-G31 behind ARM's
proprietary blob, no X server, no compositor, and a gamepad.

Three separate gaps, each closed differently:

**No window system, no desktop GL.** PortMaster's
[Westonpack](https://github.com/binarycounter/Westonpack) runtime
(`weston_pkg_0.2`) exists precisely for this: it supplies Weston, Xwayland,
X11 client libraries, and GL 2.1 via GL4ES on top of GLES. The launcher runs
SDR++ through `westonwrap.sh` in `headless noop kiosk crusty_glx_gl4es` mode —
GLX faked over SDL2, no real compositor, which is what works on Mali-blob
devices.

The build itself needs no patches, which is the pleasant surprise here.
SDR++'s GLFW backend already walks a fallback ladder — desktop GL 3.0, then
GLES 3.1, then GL 2.1 — and every version it tries uses GLSL 1.20 or ES 3.00.
GL4ES lands on the GL 2.1 rung. The only direct GL calls SDR++ makes outside
of Dear ImGui are texture uploads in the waterfall widget, all of which are
fine under GL 2.1.

**No mouse.** SDR++ has no gamepad support at all, so gptokeyb maps the left
stick to a pointer, with a slow modifier and single-step nudging for hitting
narrow targets like VFO edges. See `port/sdrpp/sdrpp.gptk.*`.

**Desktop-scale defaults.** A 65536-point FFT at 20 fps will not run on this
SoC. The launcher seeds a device-appropriate `config.json` on first run —
8192-point FFT, 15 fps, window and menu sized from `$DISPLAY_WIDTH`/`$DISPLAY_HEIGHT`
— and then leaves the user's settings alone forever after.

## How the build works

| Stage | Where | What |
|---|---|---|
| `make image` | host | Builds `docker/Dockerfile` on top of the official PortMaster aarch64 builder |
| `make build` | container | Clones SDR++, compiles, stages a relocatable tree into `build/sdrpp/` |
| `make smoke` | container | Runs the staged binary under Xvfb + llvmpipe and asserts it starts |
| `make package` | host | Assembles `dist/sdrpp.zip` |

### Why this base image

`ghcr.io/monkeyx-net/portmaster-build-templates/portmaster-builder:aarch64-latest`
is Ubuntu 20.04 — glibc 2.31, gcc 9.4. That is not an arbitrary choice: ArkOS
on RK3326 is focal-era, and a binary linked against a newer glibc simply
refuses to start there. Build on the oldest target you intend to support.

### Native, not emulated

The container is `linux/arm64` and the build runs natively on Apple Silicon and
ARM Linux hosts — no QEMU, which is worth roughly an order of magnitude in
compile time. On an x86_64 host, run `make binfmt` once first; everything else
is identical, just slower.

### Library bundling

`scripts/bundle-libs.sh` walks the dependency graph from the binary and every
module, copies what it finds into `libs.aarch64/`, and rewrites RUNPATHs to
`$ORIGIN`-relative paths so the port works whether it lands in `/roms/ports` or
`/roms2/ports`.

It deliberately does **not** bundle four categories:

* **glibc core** — must be the device's own loader
* **X11 / Wayland client libs** — Westonpack ships these in `lib_aarch64/`
* **GL / EGL / GLES / GBM / DRM** — whichever `gl_library` mode you pick
  provides them; shadowing them is the classic route to a black screen
* **ALSA** — `libasound` drags in device-specific plugin configuration

RUNPATH rather than RPATH is intentional: `LD_LIBRARY_PATH` still wins, which
leaves an escape hatch if some firmware needs its own copy of something.

The script fails the build on any unresolved `NEEDED` entry, because the
alternative is discovering it as a port that silently does nothing.

### The smoke test

`make smoke` launches the real aarch64 binary under Xvfb with llvmpipe and
asserts: everything is aarch64, every library resolves through RUNPATH alone,
a GL context is created, every shipped module appears in the log, and no load
errors occur.

It cannot tell you anything about GL4ES, Westonpack, gptokeyb or actual
performance — only the device can. What it does catch, in about a minute and
without touching hardware, is the whole class of bundles that cannot start at
all. Most of the iteration loop for a port like this lives here.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `SDRPP_REF` | `master` | Upstream git ref to build. Pin a tag for releases. |
| `SDRPP_CMAKE_EXTRA` | — | Extra `-D` flags, e.g. to re-enable a module |
| `PORTER` | `Unknown` | Your name; written into `port.json` |
| `JOBS` | host CPU count | Parallel compile jobs |
| `PLATFORM` | `linux/arm64` | Container platform |
| `GH_USER` / `GH_REPO` | `jasiek` / `r36s-sdrplusplus` | Where the source manifests point |
| `TAG` | `latest` | Release tag used in `ports.json` download URLs |

```bash
make SDRPP_REF=1.2.1 PORTER="Your Name"
```

The enabled module set lives in `scripts/build.sh` and is trimmed for this
hardware: RTL-SDR, Airspy, AirspyHF+, HackRF and the network sources are in;
SoapySDR, LimeSDR, BladeRF, USRP, the satellite decoders and Discord presence
are out.

## Testing on the device

The R36S has **no built-in WiFi** (only the 2025 "R36S Plus" does) and one
usable USB-C OTG port. That single port is the crux of the whole setup: a WiFi
dongle and an SDR dongle both want it, and an RTL-SDR draws ~300 mA which is at
or past what the port supplies unassisted. **A powered OTG hub solves both
problems at once** and is the single most useful thing to have.

PortMaster needs the network once, to fetch the `weston_pkg_0.2` runtime. If
you'd rather not deal with WiFi at all, place it manually instead — download
[`weston_pkg_0.2.aarch64.squashfs`](https://github.com/PortsMaster/PortMaster-New/raw/main/runtimes/weston_pkg_0.2.aarch64.squashfs)
and save it as `weston_pkg_0.2.squashfs` (the generic name, which is what the
launcher looks for) in `PortMaster/libs/`.

### Fast iteration

Reinstalling through PortMaster for every change is a miserable loop for the
part of this port that actually needs iterating. With SSH reachable — ArkOS
enables it by default, and there's an `SSH Over OTG.sh` port if you have no
WiFi dongle:

```bash
make deploy DEVICE=ark@192.168.1.50   # copies only what changed, keeps conf/
make logs   DEVICE=ark@192.168.1.50   # pulls log.txt back
```

Launch from the Ports menu between the two.

### When it doesn't work

`sdrpp/log.txt` on the device captures both the launcher and the application.
Read it first. The likely failure modes, in rough order:

| Symptom | Try |
|---|---|
| Black screen, log shows GL errors | Edit `sdrpp/graphics.cfg`, e.g. `WESTON_MODE="drm gl kiosk gl4es"` |
| Exits immediately, no log at all | CRLF line endings somewhere — check `file sdrpp/*.sh` |
| Runs but no pointer | `CRUSTY_SHOW_CURSOR=1` isn't taking effect; try the `drm` backend |
| Source list empty with a dongle attached | Power. Use a powered hub before debugging anything else |
| No audio | Sinks menu, check device selection; ALSA comes from the firmware |

## Publishing

This repo self-hosts as a **PortMaster source**: users add it once and the port
shows up in the PortMaster UI alongside the official ones, with install and
update handled normally. No PR to the official repo required.

`make source` produces three files in `dist/`:

| File | Where it goes |
|---|---|
| `sdrpp.zip` | GitHub Release asset |
| `ports.json` | GitHub Release asset, next to the zip |
| `sdrpp.source.json` | What users drop into `PortMaster/config/` |

Tagging a release runs the whole pipeline in CI and attaches all three:

```bash
git tag v1.0.0 && git push --tags
```

### How it works

PortMaster's harbourmaster supports several source APIs. This uses
`PortMasterV2`, which points at a GitHub release and reads its assets — so the
binaries live on releases rather than being committed into git.

`ports.json` must be a release asset next to the zip: harbourmaster locates it
by asset name and reads the md5 from it. A release with the zip but no
`ports.json` yields a source that lists nothing at all.

### For users

Copy `sdrpp.source.json` to the device at one of:

```
/roms/ports/PortMaster/config/          # ArkOS and most CFW
/opt/system/Tools/PortMaster/config/    # some ArkOS builds
```

Then open PortMaster — SDR++ appears in the list. Updates are picked up
automatically when a new release is tagged.

### Installing without any of that

```
dist/sdrpp.zip  ->  /roms/ports/   (unzip in place)
```

First launch downloads the `weston_pkg_0.2` runtime if it isn't already
present, so the device needs network access once either way.

## Submitting to the official PortMaster repo

Not done, and it's a bigger job than it looks. Their
[AGENTS.md](https://github.com/PortsMaster/PortMaster-New/blob/main/AGENTS.md)
and PR template require a testing matrix spanning ROCKNIX, muOS, dArkOS, Knulli
and AmberELEC across several SoCs, and state plainly that a port focused on one
device is rejected. They also reject submissions that are more verbose than
comparable existing ports, so the `graphics.cfg` override hook and the
per-launch path rewriting in the launcher would need justifying or removing.
Their PR template additionally asks you to declare which parts came from an AI
assistant — all of this was, so that box needs ticking.

The conventions their guide *does* impose that we already follow: no bundled
`libstdc++`/`libgcc`/SDL2/GL, no hand-rolled `pkill` cleanup, flat
`licenses/LICENSE.<component>.txt`, LF line endings, `.sh` committed 644, and a
`runtime` entry matching `runtimes/runtimes.json` exactly.

## Status

The build pipeline is complete and verified end to end: SDR++ compiles for
aarch64 against a focal-era toolchain, the bundle is self-contained, and the
binary starts and renders under the smoke test.

**On-device behaviour has not been verified** — I don't have an R36S. The
graphics path in particular is the piece most likely to need a nudge, which is
why `WESTON_MODE` is overridable at runtime via `sdrpp/graphics.cfg` rather
than baked into the binary. See the port README for the fallbacks to try.

Before submitting to PortMaster proper, its rules require testing across the
major firmwares (ArkOS, AmberELEC, ROCKNIX, muOS) with results posted in the
`#testing-n-dev` Discord channel, plus a real gameplay screenshot at 640x480.

## Licence

The build scripts here are MIT. SDR++ is GPL-3.0 and its licence, along with
those of every bundled library, is collected into `sdrpp/licenses/` in the
package.
