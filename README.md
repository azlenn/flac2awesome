# flac2awesome

**You have a home theater setup with multiple speakers in it ?
If you do, turn your stereo FLAC files into 5.1 surround tracks, so that all speakers are used: DTS, lossless Dolby TrueHD
or lossless 6-channel FLAC.**

One self-contained script. Point it at a folder of `.flac` files and it creates 5.1 versions
that your receiver decodes as real surround: a DTS file that plays on any bit-perfect player,
a lossless Dolby TrueHD file at up to 192 kHz/24-bit, or a lossless 6-channel FLAC.

By default it builds a clean, faithful 5.1 from the stereo channels, with a properly
band-limited subwoofer (LFE) channel. Two optional modes go further: a stereo-image upmix,
and AI instrument separation where guitars and synths circle around the room.

---

## The simplest way

```bash
curl -LO https://raw.githubusercontent.com/azlenn/flac2awesome/main/flac2awesome.sh
chmod +x flac2awesome.sh
```

On a new machine, let it install what it needs (it shows every command and asks first):

```bash
./flac2awesome.sh --setup
```

Then copy `flac2awesome.sh` into the folder that contains your `.flac` files, open a terminal
there and run:

```bash
./flac2awesome.sh
```

That's it. Every FLAC in the folder is converted, and the results appear in a new `output/`
subfolder as `<name>_DTS-5.1.wav`. Play them as described in
[Playing the files](#playing-the-files).

You can also skip `--setup`: if something is missing when you convert, the script tells you
what and offers to install it. The defaults work well for most music; everything below is
optional.

---

## Quick start

```bash
./flac2awesome.sh                        # DTS 5.1, simple upmix (default)
./flac2awesome.sh --output truehd        # lossless Dolby TrueHD 5.1
./flac2awesome.sh --output flac          # lossless 6-channel FLAC, source sample rate
./flac2awesome.sh "One Song.flac"        # convert only the files you name
./flac2awesome.sh --help                 # all options
```

One-time setups (each shows its commands and asks first):

```bash
./flac2awesome.sh --setup                # basics: FFmpeg, Python 3, numpy
./flac2awesome.sh --setup-truehd         # TrueHD at 96/192 kHz (builds a patched FFmpeg, ~1 min)
./flac2awesome.sh --setup-stems          # AI stems mode (installs PyTorch + Demucs, several GB)
./flac2awesome.sh --setup-all            # all of the above
./flac2awesome.sh --check                # what is available on this system
```

### Every option, with an example

```bash
# --- output ---
./flac2awesome.sh --output dts                 # DTS 5.1 WAV, 44.1 kHz (default)
./flac2awesome.sh --output truehd              # lossless Dolby TrueHD 5.1, MP4, up to 192 kHz
./flac2awesome.sh --output flac                # lossless 6-channel FLAC, source sample rate
./flac2awesome.sh --outdir ~/Music/surround    # write results elsewhere (default: ./output)

# --- upmix ---
./flac2awesome.sh --upmix simple               # L/R front, R/L surround, (L+R)/2 center (default)
./flac2awesome.sh --upmix smart                # place sounds by their stereo position
./flac2awesome.sh --upmix stems                # AI instrument separation (needs --setup-stems)
./flac2awesome.sh --lfe off                    # 5.0 without a subwoofer channel (default: on)
./flac2awesome.sh --lfe-hz 80                  # LFE low-pass cutoff in Hz (default: 120)

# --- smart mode ---
./flac2awesome.sh --upmix smart --spread 0.4   # wider stage (default 0.6; smaller = wider)
./flac2awesome.sh --upmix smart --surround 4.5 # louder surrounds, in dB (default 3)
./flac2awesome.sh --upmix smart --center 1.0   # all centred sound from the center (default 0.8)

# --- stems mode ---
./flac2awesome.sh --upmix stems --stems-mode circle   # instruments circle the room (default)
./flac2awesome.sh --upmix stems --stems-mode glide    # glide left<->right across the back
./flac2awesome.sh --upmix stems --stems-mode placed   # fixed in the surrounds
./flac2awesome.sh --upmix stems --turn-bars 4         # circle twice as fast (default 8)
./flac2awesome.sh --upmix stems --stems-dir ./stems   # use ready-made stems, skip Demucs

# --- TrueHD ---
./flac2awesome.sh -o truehd --thd-over keep    # over-spec songs: keep full quality, don't ask
./flac2awesome.sh -o truehd --thd-over spec    # over-spec songs: stay within the spec, don't ask
./flac2awesome.sh -o truehd --thd-peak 18000000      # declared peak for normal encodes (advanced)
./flac2awesome.sh -o truehd --thd-ffmpeg /path/to/ffmpeg   # choose the TrueHD encoder binary

# --- DTS ---
./flac2awesome.sh --max-abits 13               # stricter receiver-safety limit (default 14)
./flac2awesome.sh --leadin 2                   # 2 s of silence before the audio (default 0)

# --- test aid ---
./flac2awesome.sh --solo surround              # only the surround channels play
```

Options can be combined, for example:

```bash
./flac2awesome.sh --output truehd --upmix stems --turn-bars 4 --thd-over keep
```

See [Options](#options) for full descriptions. Every option can also be given as an
environment variable (see `--help`).

---

## Choosing an output format

| | `dts` (default) | `truehd` | `flac` |
|---|---|---|---|
| Quality | lossy, 44.1 kHz | lossless, 24-bit, 48/96/192 kHz | lossless, 24-bit, source rate up to 192 kHz |
| Limits | 1.23 Mbit/s | 18 Mbit/s peak by spec (~24.5 over HDMI) | none (multichannel PCM) |
| Receiver shows | DTS | Dolby TrueHD | Multi Ch In / PCM |
| Player | any bit-perfect player | passthrough player (mpv, Kodi, PotPlayer) | any player that outputs 6 channels |
| Connection | HDMI or optical/coax | HDMI | HDMI |
| Extra setup | none | `--setup-truehd` for 96/192 kHz | none |

## Why FLAC?

flac2awesome deliberately starts from **lossless sources**. FLAC is compressed, but it decodes to
exactly the original audio, bit for bit, so the upmix and the encoder work on the full,
untouched signal:

- **One lossy step at most.** DTS is itself a lossy codec; starting from FLAC means the only data
  reduction in the whole chain is the final DTS encode (and none at all for TrueHD and FLAC
  output). Converting an MP3 would stack a second set of encoding artifacts on top of the first.
- **Clean surround channels.** Lossy formats like MP3 typically encode the difference between
  left and right ("side" signal) most coarsely, and that is exactly what upmixing steers into
  the surround speakers, where artifacts are easiest to hear.
- **Better separation.** Demucs separates instruments more cleanly from lossless audio.

Any FLAC works, from 16-bit/44.1 kHz CD rips to 24-bit/192 kHz high-resolution files.

## Features

- **One file, no installation.** Download, `chmod +x`, run.
- **Three outputs:** DTS (plays everywhere, also over optical), lossless Dolby TrueHD up to
  192 kHz/24-bit, lossless 6-channel FLAC at the source's own sample rate.
- **Three upmix modes**
  - `simple` *(default)*: front left/right = original left/right, surround left/right =
    original right/left (swapped), center = both channels combined, LFE = everything below
    120 Hz. Faithful to the original mix, no processing artifacts.
  - `smart`: analyses the stereo image and places every sound around you according to its
    position in the mix; room ambience goes to the rear.
  - `stems`: AI source separation ([Demucs](https://github.com/facebookresearch/demucs)) splits
    the song into vocals, drums, bass, guitar, piano and other. The backbone stays in front
    while guitar and synths move around the room, timed to the song's tempo.
- **Real LFE channel:** everything below 120 Hz with a steep 24 dB/octave filter.
- **Receiver-safe DTS:** frames that some hardware decoders garble are re-encoded automatically.
- **TrueHD peak check:** every TrueHD file is checked against the format's peak bitrate; you
  decide whether to keep full quality or stay within the spec.
- **Includes fixes for FFmpeg encoder bugs** (TrueHD at 96/192 kHz, DTS LFE), documented in
  [`docs/`](docs/).
- Tags are kept (TrueHD, FLAC) and cover art too (FLAC); progress bar with elapsed time and a
  per-song summary.
- **Robust with imperfect files:** if a player can play it, flac2awesome converts it, and tells
  you about anything a player would silently hide. Every source is checked against the audio
  checksum stored in each FLAC; damaged or truncated files are converted anyway (like a player
  would) with a clear warning, foreign tags (ID3v1, APEv2) are ignored with a short note, and
  unreadable files are skipped without stopping the batch. A summary at the end lists them.

## Installation and requirements

### What you need for what

| To use | You need | Installed by |
|---|---|---|
| DTS output (default) | `bash`, Python 3, FFmpeg with the `dca` encoder | `--setup` |
| 6-channel FLAC output | `bash`, Python 3, FFmpeg | `--setup` |
| TrueHD output at 48 kHz | `bash`, Python 3, FFmpeg | `--setup` |
| TrueHD output at 96/192 kHz | the above + a patched FFmpeg build (`~/.local/bin/ffmpeg-truehd`) | `--setup-truehd` |
| `smart` upmix | the above + numpy | `--setup` |
| `stems` upmix | PyTorch + Demucs in their own folder (several GB; NVIDIA GPU recommended, otherwise CPU) | `--setup-stems` |
| everything | | `--setup-all` |

`bash` is part of every Linux system, and almost every distribution includes Python 3.

### Automatic setup

```bash
./flac2awesome.sh --setup          # basics: FFmpeg (full build), Python 3, numpy
./flac2awesome.sh --setup-truehd   # optional: TrueHD at 96/192 kHz
./flac2awesome.sh --setup-stems    # optional: AI stems mode
./flac2awesome.sh --setup-all      # all three
./flac2awesome.sh --check          # show what is available
```

The setup commands detect your distribution, show the exact install command, and ask before
running it (with `sudo` when needed). Supported:

| Distribution family | Examples | Package manager |
|---|---|---|
| Fedora | Fedora, Nobara, RHEL-based | `dnf` |
| Debian | Debian, Ubuntu, Linux Mint, Pop!_OS | `apt` |
| Arch | Arch, Manjaro, EndeavourOS | `pacman` |
| openSUSE | Tumbleweed, Leap (best effort) | `zypper` |

On other systems the script still checks everything and tells you what to install.

Two details the setup handles for you:

- **Plain Fedora** ships a reduced FFmpeg (`ffmpeg-free`) without the DTS encoder. `--setup`
  explains this and offers to enable RPM Fusion and switch to the full FFmpeg. Nobara and most
  other distributions already have the full build.
- **Debian/Ubuntu** need the separate `python3-venv` package for stems mode; `--setup-stems`
  installs it.

Options for unattended or careful use:

```bash
F2A_DRY_RUN=1 ./flac2awesome.sh --setup-all   # only show what would be installed
F2A_YES=1 ./flac2awesome.sh --setup           # answer yes to every install question
```

### What the setup commands do exactly

- **`--setup`** installs your distribution's packages for FFmpeg, Python 3 and numpy, then
  verifies that FFmpeg really has the `dca`, `truehd` and `flac` encoders.
- **`--setup-truehd`** installs the build tools (`git`, `gcc`, `make`, `nasm`, `pkg-config`) if
  needed, downloads FFmpeg's source at a tested version, applies the
  [TrueHD fix](patches/0001-mlpenc-truehd-peak-bitrate.patch), builds a small FFmpeg (about a
  minute) and installs it as `~/.local/bin/ffmpeg-truehd`. Your system FFmpeg is not touched,
  and system updates cannot overwrite it.
- **`--setup-stems`** creates a Python environment in `~/.local/share/flac2awesome/stems-venv`,
  installs PyTorch (the CUDA build if `nvidia-smi` finds an NVIDIA GPU, otherwise the CPU build),
  Demucs and numpy into it, and downloads the separation model. Nothing is installed into your
  system Python. NVIDIA RTX 50-series (Blackwell) cards need driver 570 or newer. AMD and
  Intel GPUs get the CPU build (untested with their own PyTorch builds; see
  [Tested and untested](#tested-and-untested)).

### Manual installation

If you prefer to install the basics yourself:

```bash
sudo dnf install ffmpeg python3-numpy        # Nobara; on plain Fedora enable RPM Fusion first
sudo apt install ffmpeg python3-numpy        # Debian, Ubuntu, Mint
sudo pacman -S ffmpeg python-numpy           # Arch, Manjaro
sudo zypper install ffmpeg python3-numpy     # openSUSE (full FFmpeg from Packman)
```

### Uninstalling

flac2awesome itself is just the script. The optional parts live in two places:

```bash
rm ~/.local/bin/ffmpeg-truehd               # TrueHD build
rm -rf ~/.local/share/flac2awesome          # stems mode (PyTorch, Demucs, model)
```

System packages installed by `--setup` (FFmpeg, numpy) are ordinary packages; remove them with
your package manager if you no longer need them.

## Options

| Option | Default | Description |
|---|---|---|
| `-o, --output` | `dts` | `dts`: DTS 5.1 WAV (44.1 kHz). `truehd`: lossless Dolby TrueHD 5.1, 24-bit, MP4. `flac`: lossless 6-channel FLAC, 24-bit, source sample rate |
| `-d, --outdir` | `output` | output folder |
| `-u, --upmix` | `simple` | `simple`, `smart` or `stems` |
| `--lfe` | `on` | `off` = 5.0 without a subwoofer channel |
| `--lfe-hz` | `120` | LFE low-pass cutoff in Hz (24 dB/octave) |
| `--spread` | `0.6` | smart: stereo position (0–1) that reaches the surround speakers; smaller = wider |
| `--surround` | `3` | smart: surround level in dB |
| `--center` | `0.8` | smart: share of centred sound in the center speaker (0–1) |
| `--stems-mode` | `circle` | stems: `circle` (guitar and synths circle the room in opposite directions), `glide` (glide left↔right across the back), `placed` (fixed in the surrounds) |
| `--turn-bars` | `8` | stems/circle: bars per full turn; smaller = faster |
| `--stems-dir` | – | stems: use ready-made stems (`drums.flac`, `bass.flac`, `other.flac`, `vocals.flac`, `guitar.flac`, `piano.flac`) instead of running Demucs |
| `--thd-over` | `ask` | TrueHD: what to do when a song needs more than the 18 Mbit/s TrueHD peak. `ask`, `keep` (full quality, real peak declared, outside the spec) or `spec` (remove only as many low bits as needed). Without a terminal, `ask` becomes `spec` |
| `--thd-peak` | `18000000` | TrueHD: declared peak in bits/s for normal encodes (advanced) |
| `--thd-ffmpeg` | auto | TrueHD: FFmpeg binary (default: the patched build if installed, otherwise `ffmpeg`) |
| `--max-abits` | `14` | DTS: highest bit-allocation index allowed in any frame (see [Technical notes](#technical-notes)). Lower it to `13` if a receiver still garbles a passage |
| `--leadin` | `0` | DTS: seconds of digital silence before the audio |
| `--solo` | – | `surround` mutes front, center and LFE (for checking what the surrounds carry) |
| `--check` | | show which features are available |
| `--setup` | | install the basics (FFmpeg, Python 3, numpy) |
| `--setup-truehd` | | build the patched FFmpeg for 96/192 kHz TrueHD |
| `--setup-stems` | | install the AI stems mode |
| `--setup-all` | | all setup steps |
| `-V, --version` / `-h, --help` | | |

## Playing the files

### DTS (`--output dts`)

The WAV files only work if they reach the receiver **bit-perfect**; any change to the samples
destroys the DTS bitstream and you would hear loud noise instead.

- Use a player with **direct ALSA / exclusive output** (Strawberry, MPD, foobar2000 with
  WASAPI exclusive, Kodi with passthrough, …).
- Player volume at **100 %**; **ReplayGain, equalizers, crossfade, resampling and any DSP off**.
- Connect over **HDMI or S/PDIF**. The receiver should show **DTS**.

### TrueHD (`--output truehd`)

TrueHD needs a player that sends the bitstream to the receiver untouched (passthrough) over
HDMI; a "bit-perfect PCM" player such as Strawberry cannot do this.

```bash
mpv --audio-device=help | grep -i hdmi        # find your HDMI output
mpv --audio-spdif=truehd --audio-device='alsa/hdmi:CARD=NVidia,DEV=0' "output/Song_TrueHD-5.1.mp4"
```

Kodi (enable passthrough and "Dolby TrueHD capable") and PotPlayer on Windows also work. The
receiver should show **Dolby TrueHD**.

### 6-channel FLAC (`--output flac`)

The player decodes the FLAC and sends multichannel PCM, so it must output all six channels:
Strawberry with an ALSA HDMI device (e.g. `hdmi:CARD=NVidia,DEV=0`), or any player through a
PipeWire/Pulse HDMI output whose profile is set to 5.1 surround (a "Digital Stereo" profile
downmixes to stereo).

```bash
mpv --audio-device='alsa/hdmi:CARD=NVidia,DEV=0' --audio-channels=5.1 "output/Song_FLAC-5.1.flac"
```

The receiver shows multichannel PCM ("Multi Ch In" on Denon).

Tested with a Denon AVR-X2700H over HDMI from an NVIDIA graphics card, using Strawberry, mpv
(Linux) and PotPlayer (Windows).

## TrueHD details

- **Sample rate.** With the patched encoder (`--setup-truehd`), 48/96/192 kHz sources keep
  their rate and 44.1/88.2/176.4 kHz sources go up to 48/96/192 kHz, the rates Blu-ray TrueHD
  (and therefore every hardware decoder) uses. With stock FFmpeg the output is 48 kHz, because
  stock FFmpeg's 96/192 kHz TrueHD stutters on hardware decoders
  ([details](docs/ffmpeg-truehd-peak-bitrate.md)). Stems mode outputs 48 kHz.
- **Container.** MP4, because Matroska's millisecond timestamps make TrueHD passthrough stutter.
- **Peak check.** Lossless audio cannot be squeezed: a genuine 192 kHz recording can need more
  than TrueHD's 18 Mbit/s maximum in its busiest moments. Every TrueHD file is checked after
  encoding; if it goes over, flac2awesome explains and asks:

  ```
     WARNING: at 192 kHz / 24-bit this song needs up to 18.64 Mbps in 90 places (0.021%),
     above the 18.0 Mbps peak TrueHD allows. ...
       1) Keep maximum quality: 192 kHz / 24-bit, lossless. The file declares a
          18.8 Mbps peak, outside the TrueHD spec. Receivers that accept it play it
          perfectly (tested: Denon AVR-X2700H); receivers strictly limited to
          18.0 Mbps may stutter in those places.
       2) Stay within the spec, lowering quality only as much as needed: first the
          lowest bits (24 -> 23-bit = 138 dB dynamic range, far beyond audibility),
          down to 20-bit; the sample rate only if that is not enough.
     Choice [1/2]:
  ```

  Each removed bit saves about 1.15 Mbit/s at 192 kHz 5.1, so a song slightly over the limit
  usually needs just one bit (23-bit, dithered). Use `--thd-over keep` or `--thd-over spec` to
  answer in advance for batch runs.

## Imperfect source files

Every FLAC stores a checksum (MD5) of its complete audio. Before converting, flac2awesome decodes
each file once and checks it:

| Situation | What happens |
|---|---|
| Audio matches the checksum | nothing to report |
| Foreign tags appended (ID3v1, APEv2) | `note:` line; ignored, audio and FLAC tags unaffected |
| Damaged frames | `warning:` with the position (e.g. `1 damaged frame near 2:14`); converted anyway, skipping the bad frames exactly as a player would |
| File ends early (truncated) | `warning:` with how much is missing; the existing part is converted |
| No checksum stored | `note:` line; converted normally |
| Not decodable (not a FLAC file, unreadable) | `skipped:`; the batch continues |

At the end, a summary lists every damaged, skipped or failed file. The exit code is 0 when all
files were converted and 1 otherwise, so the script can be used in other scripts.

```
Done: 160 of 162 converted.
  damaged source (converted anyway): Track 07.flac: 1 damaged frame near 2:14
  skipped: notes.flac: not a FLAC file
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| DTS: loud white noise | The player is altering the samples: check volume, ReplayGain, resampling and DSP |
| DTS: receiver shows PCM | Same as above, or the output device is not passing the stream through |
| DTS: short garbled passages (often quiet intros) | `--max-abits 13` |
| TrueHD: no sound or PCM | The player is not in passthrough mode, or the wrong HDMI device is selected |
| TrueHD: stutters at 96/192 kHz | Run `--setup-truehd` (stock FFmpeg's high-rate TrueHD is not hardware-compatible) |
| FLAC: only two speakers play | The player or the PipeWire HDMI profile is downmixing to stereo |
| `lacks the encoder(s): dca` | Your FFmpeg is a reduced build: run `--setup` (on Fedora it offers RPM Fusion), or use `--output flac` |
| `stems mode is not installed` | `./flac2awesome.sh --setup-stems` |
| A setup step fails | Run it again with `F2A_DRY_RUN=1` to see the exact commands, and run them by hand |
| `note: ... tag data appended` | The source FLAC has a foreign ID3v1/APEv2 tag at the end (added by some taggers; not part of the FLAC format). Ignored automatically. To clean the file itself: `ffmpeg -i in.flac -map 0 -c:a flac -c:v copy out.flac` |
| `warning: the source is damaged` | The FLAC itself is corrupted (bad download or copy). The output has the same glitch a player would play; a fresh copy of the file is the only real fix. `flac -t file.flac` confirms |

## How it works

1. **Upmix** the stereo file to 5.1 (FL, FR, C, LFE, SL, SR):
   - *simple*: FL = L, FR = R, C = (L+R)/2, SL = R, SR = L, LFE = (L+R)/2 below `--lfe-hz`.
   - *smart*: a short-time Fourier analysis splits every time/frequency slice into *direct*
     sound and *ambience*. Direct sound gets a direction from its stereo position (centre 0°,
     front speakers ±30°, surrounds ±110°) and is panned between the two nearest speakers;
     ambience goes to the surrounds. Bass below ~150 Hz is left untouched.
   - *stems*: Demucs separates six stems. Vocals, drums and bass are anchored in front; guitar,
     synths and piano are placed or moved around the room on a beat grid detected from the drum
     stem. Anything the separation misses stays in the front speakers, so nothing is lost.
2. **Encode**
   - *DTS*: FFmpeg's `dca` encoder at several bitrates in parallel; frame by frame, the highest
     bitrate that respects the bit-allocation limit is kept, a corrected LFE is spliced in, and
     the 16-bit frames are packed into 14-bit words inside a 44.1 kHz 16-bit stereo WAV
     (the DTS-CD format).
   - *TrueHD*: one lossless encode, followed by the peak check.
   - *FLAC*: one lossless encode at the source's sample rate.

## Technical notes

- **DTS format:** DTS core, 44.1 kHz, 1234.8 kbit/s payload (rate code 22), 512-sample frames,
  14-bit packing, no IEC 61937 preamble, the same layout as commercial DTS-CDs.
- **Bit-allocation limit.** On sparse passages FFmpeg's DTS encoder raises the per-subband
  bit-allocation index up to 26. This is valid, but at least one hardware decoder garbles frames
  at index 17 and above. flac2awesome replaces such frames with the same frame encoded at a lower
  bitrate; in listening tests a limit of 14 was transparent and clean.
- **DTS LFE response.** DTS carries the LFE at 1/64 of the sample rate, and the filters roll it
  off early (−6 dB at 80 Hz, −14 dB at 120 Hz through FFmpeg's decoder). flac2awesome
  pre-compensates with two peaking EQs, so the decoded LFE follows the intended 24 dB/octave
  low-pass within 0.2 dB.
- **FFmpeg DTS LFE bug.** For 5.1, FFmpeg's DTS encoder (all releases up to 8.1.3) builds the LFE
  partly from the SR channel. flac2awesome works around it; the bug is fixed in FFmpeg's
  development branch. Details: [docs/ffmpeg-dts-lfe-history.md](docs/ffmpeg-dts-lfe-history.md).
- **FFmpeg TrueHD peak-bitrate bug.** FFmpeg's TrueHD encoder declares a fixed 9.6 Mbit/s peak,
  which 96/192 kHz multichannel streams exceed, so hardware decoders stutter. The fix
  ([patch](patches/0001-mlpenc-truehd-peak-bitrate.patch)) is applied by `--setup-truehd`.
  Details: [docs/ffmpeg-truehd-peak-bitrate.md](docs/ffmpeg-truehd-peak-bitrate.md).

## Tested and untested

**Tested by the author:**

- **Systems:** Nobara Linux (Fedora 44 based) with an NVIDIA RTX 5070 Ti, and a fresh,
  headless Debian 13 virtual machine with an NVIDIA RTX 4070 Ti SUPER (every setup step,
  every output and the handling of damaged files).
- **Playback:** Denon AVR-X2700H over HDMI from an NVIDIA graphics card; players Strawberry
  (DTS, FLAC), mpv (TrueHD, FLAC) on Linux and PotPlayer (TrueHD) on Windows.

**Untested so far** (reports welcome):

- **AMD and Intel GPUs for stems mode.** `--setup-stems` installs PyTorch's CUDA build only
  when it finds an NVIDIA GPU; on any other system it installs the CPU build. Stems mode then
  works, but separation is much slower. PyTorch also has builds for AMD (ROCm) and Intel GPUs,
  but the setup does not install them. Every other feature does not use the GPU at all.
- **Windows (WSL2).** The script should run in WSL2 with Ubuntu or Debian like on any Linux
  system, and WSL2 can use an NVIDIA GPU through the normal Windows driver. Playback then
  happens in Windows (TrueHD: PotPlayer or Kodi with passthrough; DTS: a bit-perfect player
  in WASAPI exclusive mode). If you edit the script with Windows tools, convert its line
  endings back with `dos2unix flac2awesome.sh`.
- **Arch and openSUSE.** The setup supports them, but it has only been tested on Fedora-based
  systems and Debian.
- **Other receivers.** DTS and FLAC output follow established formats and should work
  everywhere. The bit-allocation limit (`--max-abits`) and TrueHD above 18 Mbit/s
  (`--thd-over keep`) were tuned on one receiver; other decoders may behave differently.
- **macOS** is not supported (the setup and some commands are Linux-specific).

## Limitations

- DTS output is 44.1 kHz DTS core only (no DTS-HD / DTS:X); higher-rate sources are resampled.
- FFmpeg's DTS and TrueHD encoders are marked experimental. With the workarounds and fixes
  included here they play correctly on the tested hardware; every TrueHD file is verified by the
  peak check, and all output decodes correctly with FFmpeg.
- TrueHD and 6-channel FLAC need HDMI (optical/coax cannot carry them).
- Upmixing creates a surround version; it cannot recover what was never in the stereo mix.
  Narrow, centre-heavy mixes give subtler results in `smart` mode.
- Stems mode needs several GB of Python packages and is much slower without a GPU.
- Linux only. Windows via WSL2 and non-NVIDIA GPUs are untested (see
  [Tested and untested](#tested-and-untested)).

## Roadmap

- More input formats, starting with MP3 (and AAC/M4A, Ogg Vorbis, WAV, ALAC). FFmpeg already
  decodes them; lossy sources will work, with the trade-off explained in [Why FLAC?](#why-flac).
- Dolby Digital output for maximum compatibility.
- A centre "dead zone" for the `smart` upmix, so slightly off-centre vocals stay in the middle.

## Repository contents

| Path | |
|---|---|
| `flac2awesome.sh` | the tool (everything needed is inside this one file) |
| `docs/` | write-ups of the two FFmpeg encoder bugs found during development |
| `patches/` | the FFmpeg TrueHD fix as a standalone patch (also built in via `--setup-truehd`) |
| `tools/thd_peak_check.py` | checks a TrueHD stream against its declared peak bitrate |
| `tools/stems_dump.py` | exports Demucs stems to FLAC (for `--stems-dir` or inspection) |

## License

flac2awesome is free software, released under the **GNU General Public License v3.0 or later**
(see [LICENSE](LICENSE)).

### Third-party components

flac2awesome does not bundle any third-party binaries or model files. It calls or downloads:

- **FFmpeg** (LGPL-2.1+ / GPL). The DTS bit-allocation Huffman tables in the frame parser come
  from FFmpeg's `libavcodec/dcahuff.c` (LGPL-2.1+), which defines them per ETSI TS 102 114.
  `--setup-truehd` downloads FFmpeg's source and builds it locally with the included patch; the
  resulting binary is LGPL-2.1+, and the patch is offered under FFmpeg's license so it can be
  used upstream.
- **numpy** (BSD-3-Clause), **PyTorch** (BSD-3-Clause), **Demucs code** (MIT).
- **Demucs pretrained weights** (stems mode only) are downloaded from Meta's servers by
  `--setup-stems`. **Their license is not clearly stated**: the author has described them as
  provided for research purposes, and they are not covered by the code's MIT license. Check the
  terms yourself before any commercial use.
- **NVIDIA CUDA** (optional, stems mode on GPU) is proprietary software from NVIDIA.

## Trademark notice

DTS is a registered trademark of DTS, Inc. Dolby and Dolby TrueHD are trademarks of Dolby
Laboratories. This project is not affiliated with, endorsed by or sponsored by DTS, Inc. or
Dolby Laboratories. "DTS" and "TrueHD" refer only to the bitstream formats of the output.

## Acknowledgements

- The FFmpeg developers, for the open-source DTS and TrueHD encoders and decoders.
- Alexandre Défossez and Meta AI Research, for Demucs.

---

Created by Stevan Azlen. Developed with AI assistance (Claude, Anthropic) and tested on the
author's own system (see [Playing the files](#playing-the-files)).
