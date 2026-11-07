# FFmpeg DTS encoder: 5.1 LFE channel built partly from the SR channel

**Component:** `libavcodec/dcaenc.c` (DTS Coherent Acoustics encoder)
**Affected:** all FFmpeg releases up to and including 8.1.3
**Status:** **fixed upstream** in master by commit
[`f391d256fd`](https://github.com/FFmpeg/FFmpeg/commit/f391d256fd) (2026-09-15, "avcodec/dcaenc:
fill the LFE history from the LFE channel"), which is expected in FFmpeg 8.2. That commit
describes the issue as an out-of-array read found by fuzzing. This note documents its
**audible effect**, which the commit does not mention.

## Summary

For 5.1 input, `shift_history()` filled the encoder's history buffer for the LFE channel
using `channel_order_tab[ch]`. The 5.1 entry of `channel_reorder_lfe` has only five valid
entries (the full-band channels), so for the LFE slot it read index `-1`: the sample just
before the current one, which in interleaved 5.1(side) input is the **SR** channel of the
previous sample. `lfe_downsample()` uses that history as the start of its 512-tap decimation
filter, so every LFE output sample was a mix of the real LFE and low-passed SR.

## Audible effect

- When SR carries little bass, which is typical of film and music 5.1, the decoded LFE comes
  out too quiet and poorly correlated with the input LFE.
- In an upmix where SR is a copy of a front channel, the error is partly masked, because SR
  then contains similar bass.
- Measured with FFmpeg 6.1 (encoder and decoder) on a 5.1 music upmix whose surrounds carried
  only ambience (no bass), LFE low-passed at 100 Hz, 1234.8 kbit/s:

  | | Decoded LFE level vs input | Correlation with input LFE | Signal-to-error |
  |---|---|---|---|
  | stock encoder | **−7.3 dB** | **0.75** | **1.2 dB** |
  | with the workaround below | −2.8 dB | 0.96 | 10.7 dB |

  With the workaround, the remaining difference is the normal DTS LFE roll-off described at
  the end of this note (coherence about 1.0 across the bass range).

## Workaround for released FFmpeg versions (as used in flac2awesome)

Run one additional encode in which the SR input carries the LFE signal, so the buggy history
read sees LFE data. That encode's 72 bits of LFE data per frame (8 samples × 8 bits + 8-bit
scale factor), located right after the bit allocation and the 8 bits per active band of
transition modes and scale factors, are then copied into each frame of the final stream.
Measured result: LFE coherence with the input about **1.0** across the bass range, time-aligned
with the main channels.

The workaround is harmless with fixed FFmpeg versions: the extra encode then simply produces
the same, correct LFE data.

## Related: DTS LFE frequency response

Independent of the bug, the DTS LFE path (64× decimation in FFmpeg's encoder plus the
decoder's interpolation filter) rolls off early, measured through FFmpeg's decoder:

| Frequency | 40 Hz | 60 Hz | 80 Hz | 100 Hz | 120 Hz |
|---|---|---|---|---|---|
| Level | −1.6 dB | −3.3 dB | −6.2 dB | −9.3 dB | −14.2 dB |

flac2awesome pre-compensates this with two peaking EQs in the LFE path (131.3 Hz, Q 2.345,
+11.2 dB; 106 Hz, Q 0.779, +4.97 dB), so the decoded LFE matches a 120 Hz 24 dB/octave
low-pass within 0.2 dB. Upstream commit `8ba5dc011b` (2026-10-10) changed how the encoder's
LFE filter table is computed, so these numbers may differ slightly with FFmpeg 8.2 and later.

---
Found while developing [flac2awesome](../README.md).

*This analysis was developed with AI assistance (Claude, Anthropic); the workaround was verified on real hardware by the author.*
