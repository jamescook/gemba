# Internals

Implementation notes for contributors and the curious.

## Color Correction

The GBA's LCD has a gamma of ~3.2 and significant channel cross-talk between
R, G, and B subpixels. Game artists designed sprites with exaggerated,
washed-out colors to compensate — so running those same colors on a modern
display looks wrong.

Color correction is optional (off by default) and can be toggled in the
settings UI or via `Gemba::Core#color_correction=`.

When enabled, Gemba uses the [Pokefan531 color correction formula](https://github.com/libretro/glsl-shaders/blob/master/handheld/shaders/color/gba-color.glsl)
(from libretro's `gba-color.glsl`) to approximate the original LCD appearance:

```
nr = 0.82*r + 0.125*g + 0.195*b
ng = 0.24*r + 0.665*g + 0.075*b
nb = -0.06*r + 0.21*g + 0.73*b
```

To avoid per-pixel math every frame, a 128KB lookup table (32x32x32 entries,
one per RGB555 input color) is built once when the feature is enabled. Each
frame, the LUT is applied during the BGR→ARGB conversion pass that already
runs for every pixel.

## Frame Blending

Blends the current and previous frame 50/50 to reduce flicker from GBA games
that rely on LCD ghosting (e.g. transparency effects in Pokemon).

The blend uses a bit trick that avoids branching and overflow:

```c
blended = ((cur & 0xFEFEFEFE) >> 1)
        + ((prev & 0xFEFEFEFE) >> 1)
        + (cur & prev & 0x01010101);
```

Right-shift each channel by 1, add, then recover the dropped LSBs with a
final AND. No conditionals, no clamping.

## Recording Format (.grec)

Recordings use a custom binary format optimized for low overhead during
gameplay.

### Structure

```
[Header - 32 bytes]
  "GEMBAREC" magic (8 bytes)
  version u8, width u16le, height u16le
  fps_num u32le, fps_den u32le (262144/4389 = ~59.7272 Hz)
  audio_rate u32le, channels u8, bits u8
  5 bytes reserved

[Per-frame - variable]
  change_pct u8        — what % of pixels changed (0-100)
  video_len u32le      — compressed video byte count
  video_data [N bytes] — zlib(xor_delta(current, previous))
  audio_len u32le      — raw PCM byte count
  audio_data [M bytes] — s16le stereo PCM

[Footer - 8 bytes]
  frame_count u32le
  "GEND" magic
```

### Delta Compression

Each frame is XOR'd against the previous frame before compression. Static
areas become zeroes, which compress extremely well with zlib. Even at zlib
level 1 (fastest), this yields 20-30% compression on typical gameplay.

The XOR delta and pixel change counting are implemented in C
(`Gemba.xor_delta`, `Gemba.count_changed_pixels`) to keep the hot path fast.

### Background I/O

A `Thread::Queue` pipeline decouples the emulation loop from disk writes.
Frames are batched in groups of 60 (~1 second), then flushed to disk by a
background writer thread. This prevents frame drops when the OS stalls on I/O.

CRuby's GVL (Global VM Lock) is released automatically by both
`Thread::Queue#pop` (while waiting for work) and `IO#write` (during the
actual disk write), so the writer thread never blocks the emulation loop.
This is the same reason `rb_thread_call_without_gvl` is used in the C
extension for `run_frame` — keeping the GVL free lets the Tk event loop and
background threads run concurrently with CPU-intensive work.

### Decoding

The decoder (`gemba decode`) uses a two-pass approach:

1. **Pass 1:** Extract audio to a tempfile, count frames, skip video data
2. **Pass 2:** Decode video one frame at a time, piping raw pixels to ffmpeg

Only one decoded frame lives in memory at a time — RAM usage is constant
regardless of recording length. FFmpeg handles scaling with nearest-neighbor
interpolation (`-sws_flags neighbor`) for pixel-perfect output.

## Audio Sync (Dynamic Rate Control)

> **Note:** This implementation hasn't been battle-tested on hardware with
> real audio timing issues — the author's machines sync fine with or without
> DRC. The algorithm is sound in theory but may need tuning on systems with
> poor audio clock accuracy or high-latency drivers. Leaving it as-is for now.

The emulation loop uses wall-clock frame pacing with proportional feedback on
the audio buffer fill level, based on Near/byuu's algorithm:

```
fill  = queued_samples / buffer_capacity   (0.0 to 1.0)
ratio = (1 - 0.005) + 2 * fill * 0.005
next_frame += frame_period * ratio
```

- Buffer starving (fill=0%) → ratio 0.995 → emulator speeds up slightly
- Buffer at target (fill=50%) → ratio 1.000 → no adjustment
- Buffer full (fill=100%) → ratio 1.005 → emulator slows down slightly

The buffer naturally settles around 50% full. The +/-0.5% limit keeps pitch
and speed shifts imperceptible.

Reference: [Near/byuu's rate control paper](https://docs.libretro.com/guides/ratecontrol.pdf)
