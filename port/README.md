# SDR++

A bloat-free, cross-platform software defined radio receiver by Alexandre Rouma,
running natively on your handheld.

Upstream: <https://github.com/AlexandreRouma/SDRPlusPlus> (GPL-3.0)

## What you need

SDR++ is a receiver front-end, not a radio in itself. To hear anything locally
you need a USB SDR dongle. Built in this port:

| Hardware | Notes |
|---|---|
| RTL-SDR (R820T2 / R828D / V3 / V4) | The obvious starting point. ~500 kHz–1.7 GHz. |
| Airspy R2 / Mini | Works, but the sample rates will tax the CPU. |
| AirspyHF+ / Discovery | Excellent on HF, and gentle on the CPU. |
| HackRF One | Receive only in this port. |

No hardware to hand? These sources need nothing but a network:

* **RTL-TCP** — connect to an `rtl_tcp` server on your LAN
* **SpyServer** — including the many public SpyServers on the internet
* **SDR++ Server** — SDR++'s own, more efficient remote protocol
* **File Source** — play back recorded `.wav` IQ files
* **Hermes / RFspace / Spectran HTTP** — networked receivers

### Connecting a dongle

Use the USB OTG port. **A powered OTG hub is strongly recommended.** An RTL-SDR
pulls roughly 300 mA, which is at or beyond what these handhelds supply from the
OTG port alone; the usual symptom of an underpowered dongle is the device
appearing in the source list and then failing the moment you press Play.

## Controls

SDR++ is a mouse-driven desktop UI. There is no gamepad navigation upstream, so
this port maps a pointer onto the controls:

| Input | Action |
|---|---|
| Left stick | Move pointer |
| A | Left click |
| B | Right click |
| Hold X or L1 | Slow the pointer down for fine positioning |
| Right stick / D-pad | Nudge the pointer one step at a time |
| Y | Toggle fullscreen |
| L2 / R2 | Page up / page down |
| Start | Enter |
| Select | Escape |
| *Device exit hotkey* | Quit (varies by firmware — usually Select+Start) |

Grabbing the edge of a VFO to change bandwidth is the fiddliest thing you will
do. Hold X and use the d-pad.

## First run

The port writes a device-appropriate configuration on first launch: window
sized to your screen, 8192-point FFT and a 15 fps waterfall instead of the
desktop defaults, which no RK3326-class device can sustain. Your own changes
afterwards are preserved — delete `sdrpp/conf/config.json` to get the defaults
back.

Audio comes out of the headphone jack through the **Audio Sink** module. If you
get no sound, open the Sinks menu and check the device selection.

## Performance notes

This is a demanding application on a 1.3 GHz Cortex-A35. If it struggles:

* Lower the sample rate at the source — 250–1024 kHz is plenty for FM/AM voice
* Drop the FFT size (Display menu) to 4096 or 2048
* Reduce the waterfall frame rate to 10 fps
* Turn off "Full waterfall update"

## Troubleshooting

`sdrpp/log.txt` in the port folder captures everything from the launcher and
the application. It is the first thing to look at, and the first thing to
attach if you report a problem.

If the screen stays black, edit (or create) `sdrpp/graphics.cfg` and try a
different renderer, e.g.:

```
WESTON_MODE="drm gl kiosk gl4es"
```

## Credits

* **SDR++** — Alexandre Rouma and contributors, GPL-3.0
* **Westonpack** — binarycounter, for making X11/OpenGL apps possible on these devices
* **PortMaster** — the team and community
