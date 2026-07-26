# Patches

Applied to the upstream SDR++ checkout by `scripts/build.sh`, in filename
order, before configuring. Each is a plain `git diff` — regenerate with
`git -C work/src diff > patches/NNNN-name.patch`.

Keep this list short. Everything here is a maintenance cost on every upstream
bump; if a change is genuinely useful it belongs upstream, not here.

## 0001-audio-sink-guard-empty-device-list.patch

`AudioSink::selectById()` indexes `devList[id]` without checking that the list
has anything in it. When RtAudio finds no audio output device, the constructor
path `selectByName("") -> selectFirst() -> selectById(0)` dereferences an empty
vector and SDR++ segfaults during startup, before any window appears.

This is easy to hit on a handheld: audio hardware that is busy, missing from
`/dev/snd`, or hidden by permissions all produce an empty device list. The
failure mode is the worst kind for a port — the launcher exits instantly and
the user sees the menu again with no explanation.

The patch adds bounds checks to `selectById()` and `doStart()` and an early
return in `selectFirst()`, so SDR++ starts normally and simply has no audio
sink available, logging why.

Worth sending upstream.
