# FFmpeg TrueHD encoder: fixed 9.6 Mbps peak bitrate makes 96/192 kHz streams stutter on hardware decoders

**Component:** `libavcodec/mlpenc.c` (TrueHD encoder)
**Affected:** FFmpeg 6.1, 8.1.3 and current master (tested at commit `5d85b7bfb2`, 2026-11-06)
**Status:** not fixed upstream at the time of writing. Patch below.

## Summary

The TrueHD encoder writes a fixed peak data rate of **9.6 Mbps** into every major sync
header, for every sample rate and channel layout, and never checks that the stream respects
it. Multichannel streams at 96 kHz and above routinely exceed that value. FFmpeg's own decoder
ignores the field, so the streams decode bit-exact, but a hardware decoder that sizes its
input buffering from the declared peak stutters throughout playback.

Changing only the declared peak to TrueHD's maximum of 18 Mbps makes the same audio play
smoothly on hardware at 96 and 192 kHz.

## Symptom

- 5.1 TrueHD at 48 kHz from FFmpeg plays correctly over HDMI passthrough.
- The same audio encoded at **96 kHz or 192 kHz** is recognised by the receiver ("Dolby
  TrueHD" shown), but **playback is choppy from start to finish**.
- Reproduced with two independent playback chains into the same receiver: mpv 0.41
  (`--audio-spdif=truehd`, ALSA HDMI) on Linux, and PotPlayer on Windows.
- Changing the container (MP4 instead of MKV) or `-max_interval` (8, 16, 128) does not help.

## Cause

In `mlp_encode_init()`:

```c
ctx->coded_peak_bitrate = mlp_peak_bitrate(9600000, avctx->sample_rate);
```

The value is written to the `peak_data_rate` field of every major sync. It is a promise to
the decoder that no access unit exceeds this rate. 9.6 Mbps is the MLP / DVD-Audio limit. For
TrueHD the format allows up to 18 Mbps, and real high-rate multichannel content needs more
than 9.6 Mbps.

## Evidence

Each access unit lasts 1/1200 s. Per-unit bitrate measured with
[`tools/thd_peak_check.py`](../tools/thd_peak_check.py) on 5.1, 24-bit music:

| Stream | Average | Largest AU | Declared peak | AUs above declared peak | Hardware playback |
|---|---|---|---|---|---|
| 48 kHz, stock encoder | 4.71 Mbps | 7.89 Mbps | 9.60 Mbps | 0 | smooth |
| 96 kHz, stock encoder | 6.46 Mbps | 11.12 Mbps | 9.59 Mbps | 325 (0.9 %) | **choppy** |
| 96 kHz, patched | 6.46 Mbps | 11.12 Mbps | 17.99 Mbps | 0 | smooth |
| 192 kHz, patched | 8.82 Mbps | 15.49 Mbps | 17.99 Mbps | 0 | smooth |

The stock and patched 96 kHz streams carry identical audio data. Only the declared peak
differs, and only the patched one plays smoothly.

A real 24-bit/96 kHz recording (6½ minutes, 5.1 upmix) averaged 8.2 Mbps with the patched
encoder and played correctly.

## Reproduction (no external files needed)

```bash
# 10 s of 5.1 pink noise at 96 kHz, 24-bit
ffmpeg -f lavfi -i "anoisesrc=color=pink:amplitude=0.25:sample_rate=96000:seed=1" -t 10 \
  -af "pan=5.1(side)|FL=c0|FR=0.9*c0|FC=0.7*c0|LFE=0.5*c0|SL=0.6*c0|SR=0.5*c0" \
  -c:a pcm_s32le in96.wav

ffmpeg -i in96.wav -c:a truehd -strict -2 -sample_fmt s32p out96.mp4
ffmpeg -i out96.mp4 -c copy -f truehd out96.thd
python3 tools/thd_peak_check.py out96.thd
```

| Encoder | Result |
|---|---|
| stock | avg 11.42 Mbps, max 13.56 Mbps, declared 9.59 Mbps, **100 % of access units above it** |
| patched | same audio, declared 17.99 Mbps, 0 access units above it |

Both outputs decode bit-exact to the 24-bit input. At 48 kHz the same signal stays below
9.6 Mbps with either encoder.

## Fix

[`0001-mlpenc-truehd-peak-bitrate.patch`](../patches/0001-mlpenc-truehd-peak-bitrate.patch)
(flac2awesome users get it automatically with `./flac2awesome.sh --setup-truehd`):

- adds an encoder option `-peak_bitrate` (bits/s, `0` = automatic);
- automatic: **18 Mbps for TrueHD**, **9.6 Mbps kept for MLP** (DVD-Audio limit).

```c
if (!ctx->peak_bitrate)
    ctx->peak_bitrate = avctx->codec_id == AV_CODEC_ID_TRUEHD ? 18000000 : 9600000;
ctx->coded_peak_bitrate = mlp_peak_bitrate(ctx->peak_bitrate, avctx->sample_rate);
```

## Verification

- All outputs decode **bit-exact** with unpatched FFmpeg (6.1 and 8.x), so the streams stay
  standard TrueHD.
- 0 access units above the declared peak at 48, 96 and 192 kHz (music test material).
- FFmpeg's S/PDIF (passthrough) muxer reports no warnings.
- Hardware: Denon AVR-X2700H via NVIDIA HDMI. 96 and 192 kHz play smoothly, including seeking
  (PotPlayer, Windows), and a real 24/96 recording played correctly (mpv, Linux).

## Limitations and suggestions

- The patch corrects the **declared** value; the encoder still does not **enforce** a peak.
  Nearly incompressible content can exceed even 18 Mbps: 5.1 pink noise at 192 kHz averages
  22.6 Mbps. Ordinary music, with little energy above 22 kHz, stays well below. A complete
  fix would compute the real peak, or limit it and report an error when a lossless encode
  cannot fit.
- A smarter automatic value (for example from sample rate × channels × word length, capped
  at 18 Mbps) would be closer to what commercial encoders signal.

## Related observation: MKV timestamps

Not a bug in the encoder, but relevant for anyone testing: at 48 kHz/24-bit, the same TrueHD
stream played smoothly from **MP4** but **choppy from MKV** over passthrough. A TrueHD access
unit lasts 0.83 ms, and Matroska's default 1 ms timestamp resolution gives several units the
same timestamp. FFmpeg warns `non monotonically increasing dts` when repacking such files for
S/PDIF. MP4 (time base = sample rate) avoids the problem.

---
Found and fixed while developing [flac2awesome](../README.md). The FFmpeg developers are
welcome to use the patch, adapt it or take a different approach; it is offered under
FFmpeg's license (LGPL-2.1-or-later).

*This analysis and the patch were developed with AI assistance (Claude, Anthropic) and verified on real hardware by the author.*
