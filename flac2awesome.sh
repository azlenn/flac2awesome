#!/usr/bin/env bash
# flac2awesome - turn stereo FLAC files into 5.1 surround for an AV receiver
#
#   DTS (default) . lossless Dolby TrueHD . lossless 6-channel FLAC
#
# https://github.com/azlenn/flac2awesome  (GPL-3.0-or-later)
# Copyright (C) 2026 Stevan Azlen <azlenn@gmail.com>
# Developed with AI assistance (Claude, Anthropic).
#
# Run ./flac2awesome.sh --help for all options.

set -euo pipefail
shopt -s nullglob nocaseglob

VERSION="1.0.0"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/flac2awesome"
STEMS_VENV="$DATA_DIR/stems-venv"
TRUEHD_BIN="$HOME/.local/bin/ffmpeg-truehd"
FFMPEG_COMMIT="5d85b7bfb2b024fd367ae3a938b4ac46a39e3a26"   # tested base for the TrueHD patch

usage() {
cat <<'USAGE'
flac2awesome - stereo FLAC to 5.1 surround (DTS, Dolby TrueHD or 6-channel FLAC)

Usage:
  flac2awesome.sh [options] [file.flac ...]

  Without file arguments, every .flac file in the current folder is converted.
  Results go to ./output/ (change with --outdir).

Output:
  -o, --output FORMAT    dts     DTS 5.1 WAV, 44.1 kHz, for bit-perfect PCM players (default)
                         truehd  lossless Dolby TrueHD 5.1, 24-bit, MP4 (passthrough player)
                         flac    lossless 6-channel FLAC, 24-bit, source sample rate
  -d, --outdir DIR       output folder (default: output)

Upmix:
  -u, --upmix MODE       simple  L/R front, R/L surround, (L+R)/2 center (default)
                         smart   places sounds around you by their stereo position
                         stems   AI instrument separation (needs --setup-stems)
      --lfe on|off       subwoofer (LFE) channel (default: on; off = 5.0)
      --lfe-hz N         LFE low-pass cutoff in Hz, 24 dB/octave (default: 120)
      --spread N         smart: stereo position (0..1) that reaches the surrounds;
                         smaller = wider (default: 0.6)
      --surround DB      smart: surround level in dB (default: 3)
      --center N         smart: share of centred sound in the center, 0..1 (default: 0.8)
      --stems-mode MODE  stems: circle | glide | placed (default: circle)
      --turn-bars N      stems/circle: bars per full turn (default: 8)
      --stems-dir DIR    stems: use ready-made stems DIR/{drums,bass,other,vocals,
                         guitar,piano}.flac instead of running Demucs

TrueHD:
      --thd-over MODE    when a song needs more than TrueHD's 18 Mbit/s peak:
                         ask   explain and ask (default; no terminal = spec)
                         keep  keep full quality, declare the real peak (outside spec)
                         spec  stay within spec, removing only as many low bits as needed
      --thd-peak BPS     declared peak in bits/s for normal encodes (default: 18000000)
      --thd-ffmpeg PATH  FFmpeg binary for TrueHD (default: patched build if installed)

DTS:
      --max-abits N      receiver-safety limit for DTS bit allocation (default: 14)
      --leadin S         seconds of silence before the audio (default: 0)

Setup (asks before installing anything; shows every command first):
      --check            show which features are available on this system
      --setup            install the basics: FFmpeg (full build), Python 3, numpy
      --setup-truehd     build the patched FFmpeg for 96/192 kHz TrueHD
                         (installs ~/.local/bin/ffmpeg-truehd, about a minute)
      --setup-stems      install the AI stems mode (Python venv with PyTorch and Demucs,
                         GPU build if an NVIDIA GPU is present; several GB)
      --setup-all        all of the above
                         F2A_DRY_RUN=1 shows the commands without running them,
                         F2A_YES=1 answers yes to the install questions.

Other:
      --solo surround    test aid: only the surround channels play
  -V, --version          show the version
  -h, --help             show this help

Examples:
  ./flac2awesome.sh --setup          # first time on a new machine
  ./flac2awesome.sh
  ./flac2awesome.sh --output truehd
  ./flac2awesome.sh --output flac --upmix smart
  ./flac2awesome.sh --upmix stems --turn-bars 4 "My Song.flac"

All options can also be set as environment variables (OUTPUT, DTS_UPMIX, DTS_LFE,
DTS_LFE_HZ, DTS_SPREAD, DTS_SURROUND, DTS_CENTER, DTS_STEMS_MODE, DTS_TURN_BARS,
DTS_STEMS_DIR, DTS_MAXABITS, DTS_LEADIN, DTS_SOLO, THD_OVER, THD_PEAK, THD_FFMPEG).
USAGE
}

die() { echo "flac2awesome: $*" >&2; exit 1; }

# ------------------------------------------------------------------ dependencies
# Detects the distribution, maps the tools flac2awesome needs to package names, shows every
# install command before running it and asks first. F2A_DRY_RUN=1: only show the commands.
# F2A_YES=1: answer yes to install questions (for unattended setups).
DISTRO_ID=""; DISTRO_FAMILY="unknown"
OS_RELEASE="${F2A_OS_RELEASE:-/etc/os-release}"   # (override only for testing)
if [ -r "$OS_RELEASE" ]; then
  DISTRO_ID="$(. "$OS_RELEASE"; echo "${ID:-}")"
  _like="$(. "$OS_RELEASE"; echo "${ID:-} ${ID_LIKE:-}")"
  case " $_like " in
    *" fedora "*|*" rhel "*|*" centos "*) DISTRO_FAMILY="fedora" ;;
    *" debian "*|*" ubuntu "*)            DISTRO_FAMILY="debian" ;;
    *" arch "*)                           DISTRO_FAMILY="arch" ;;
    *" suse "*|*" opensuse "*)            DISTRO_FAMILY="suse" ;;
  esac
fi

pkgs_for() {   # pkgs_for <need...>: package names for this distribution
  local n out=()
  for n in "$@"; do
    case "$DISTRO_FAMILY:$n" in
      fedora:ffmpeg|debian:ffmpeg|arch:ffmpeg|suse:ffmpeg) out+=(ffmpeg) ;;
      arch:python3)  out+=(python) ;;
      *:python3)     out+=(python3) ;;
      arch:numpy)    out+=(python-numpy) ;;
      *:numpy)       out+=(python3-numpy) ;;
      debian:venv)   out+=(python3-venv) ;;
      arch:venv)     out+=(python) ;;
      *:venv)        out+=(python3) ;;
      fedora:build)  out+=(git gcc make nasm pkgconf-pkg-config) ;;
      arch:build)    out+=(git gcc make nasm pkgconf) ;;
      *:build)       out+=(git gcc make nasm pkg-config) ;;
    esac
  done
  echo "${out[*]}"
}

install_cmd() {   # install_cmd <packages...>: the command line for this distribution
  local sudo=""; [ "$(id -u)" -ne 0 ] && sudo="sudo "
  case "$DISTRO_FAMILY" in
    fedora) echo "${sudo}dnf install -y $*" ;;
    debian) echo "${sudo}apt-get update && ${sudo}apt-get install -y $*" ;;
    arch)   echo "${sudo}pacman -S --needed --noconfirm $*" ;;
    suse)   echo "${sudo}zypper install -y $*" ;;
    *)      echo "" ;;
  esac
}

confirm() {   # confirm <question>: yes/no, default yes; no terminal = no (unless F2A_YES=1)
  [ "${F2A_YES:-}" = 1 ] && return 0
  local a
  { exec 3</dev/tty; } 2>/dev/null || return 1
  printf "%s [Y/n] " "$1" >/dev/tty
  read -r a <&3 || a="n"; exec 3<&-
  case "$a" in ""|y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}

run_cmd() {   # show, then run (unless dry run)
  echo "  + $*"
  [ "${F2A_DRY_RUN:-}" = 1 ] && return 0
  if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null; then
    echo "  (sudo is not available: run the command above as root)"; return 1
  fi
  bash -c "$*"
}

install_needs() {   # install_needs <reason> <need...>: offer to install, return 0 if done
  local reason="$1"; shift
  local pk cmd; pk="$(pkgs_for "$@")"; cmd="$(install_cmd $pk)"
  if [ -z "$cmd" ] || [ -z "$pk" ]; then
    echo "$reason: please install $* with your package manager." >&2; return 1
  fi
  echo "$reason. It can be installed with:"
  echo "  $cmd"
  if confirm "Install it now?"; then run_cmd "$cmd"; return; fi
  return 1
}

ffmpeg_encoders() { ffmpeg -hide_banner -encoders 2>/dev/null || true; }
ffmpeg_ok() {   # ffmpeg_ok [encoder...]: ffmpeg + ffprobe present and have the encoders
  command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || return 1
  local e enc; enc="$(ffmpeg_encoders)"
  for e in "$@"; do case "$enc" in *" $e "*) ;; *) return 1 ;; esac; done
}

fedora_full_ffmpeg() {   # Fedora ships a reduced FFmpeg (ffmpeg-free); the full one is in RPM Fusion
  local sudo=""; [ "$(id -u)" -ne 0 ] && sudo="sudo "
  local cmds=()
  if ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    cmds+=("${sudo}dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-\$(rpm -E %fedora).noarch.rpm")
  fi
  if rpm -q ffmpeg-free >/dev/null 2>&1; then
    cmds+=("${sudo}dnf swap -y ffmpeg-free ffmpeg --allowerasing")
  else
    cmds+=("${sudo}dnf install -y ffmpeg")
  fi
  echo "Fedora's own FFmpeg is a reduced build without some of the encoders flac2awesome uses."
  echo "The full FFmpeg comes from RPM Fusion, a widely used community repository:"
  local c; for c in "${cmds[@]}"; do echo "  $c"; done
  confirm "Enable RPM Fusion and install the full FFmpeg now?" || return 1
  for c in "${cmds[@]}"; do run_cmd "$c" || return 1; done
}

ensure_ffmpeg() {   # ensure_ffmpeg <encoder...>
  ffmpeg_ok "$@" && return 0
  if [ "$DISTRO_FAMILY" = fedora ] && [ "$DISTRO_ID" = fedora ]; then
    fedora_full_ffmpeg || true
  elif ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then
    install_needs "FFmpeg (ffmpeg and ffprobe) is missing" ffmpeg || true
  else
    install_needs "Your FFmpeg lacks encoders flac2awesome needs ($*); a full FFmpeg build is required" ffmpeg || true
  fi
  hash -r
  [ "${F2A_DRY_RUN:-}" = 1 ] && return 0
  ffmpeg_ok "$@" && return 0
  if command -v ffmpeg >/dev/null; then
    echo "flac2awesome: your FFmpeg still lacks the encoder(s): $*" >&2
    case "$DISTRO_FAMILY" in
      suse) echo "  On openSUSE, the full FFmpeg is in the Packman repository." >&2 ;;
      fedora) echo "  On Fedora-based systems, install 'ffmpeg' from RPM Fusion." >&2 ;;
    esac
    [ "${OUTPUT:-dts}" = dts ] && echo "  DTS needs the dca encoder; --output flac works with any FFmpeg." >&2
  else
    echo "flac2awesome: FFmpeg is required (ffmpeg and ffprobe)." >&2
  fi
  return 1
}

ensure_python() {
  command -v python3 >/dev/null && return 0
  install_needs "Python 3 is missing" python3 || true
  hash -r; [ "${F2A_DRY_RUN:-}" = 1 ] || command -v python3 >/dev/null
}

ensure_numpy() {
  python3 -c "import numpy" 2>/dev/null && return 0
  install_needs "This mode needs the Python package numpy" numpy || true
  [ "${F2A_DRY_RUN:-}" = 1 ] || python3 -c "import numpy" 2>/dev/null
}

setup_base() {
  echo "flac2awesome $VERSION: setting up the basics (FFmpeg, Python 3, numpy)"
  [ "$DISTRO_FAMILY" = unknown ] && echo "Unknown distribution: I can check, but not install. Install FFmpeg, Python 3 and numpy yourself."
  local ok=1 needs=()
  command -v python3 >/dev/null || needs+=(python3)
  if ! command -v ffmpeg >/dev/null || ! command -v ffprobe >/dev/null; then needs+=(ffmpeg); fi
  { command -v python3 >/dev/null && python3 -c "import numpy" 2>/dev/null; } || needs+=(numpy)
  if [ "$DISTRO_ID" = fedora ] && [[ " ${needs[*]} " == *" ffmpeg "* ]]; then
    needs=("${needs[@]/ffmpeg}")          # plain Fedora: FFmpeg comes from RPM Fusion (below)
  fi
  local n=() x; for x in "${needs[@]}"; do [ -n "$x" ] && n+=("$x"); done
  if [ ${#n[@]} -gt 0 ]; then
    install_needs "Missing: ${n[*]}" "${n[@]}" || true
    hash -r
  fi
  if [ "${F2A_DRY_RUN:-}" = 1 ]; then
    # nothing was really installed: only check an FFmpeg that is already present
    if command -v ffmpeg >/dev/null && [[ " ${n[*]} " != *" ffmpeg "* ]]; then ensure_ffmpeg dca truehd flac || true; fi
    [ "$DISTRO_ID" = fedora ] && ! command -v ffmpeg >/dev/null && { fedora_full_ffmpeg || true; }
  else
    ensure_python || ok=0
    ensure_ffmpeg dca truehd flac || ok=0
    ensure_numpy || ok=0
  fi
  echo
  if [ "${F2A_DRY_RUN:-}" = 1 ]; then
    echo "(dry run: nothing was installed)"; return 0
  fi
  check_system
  [ $ok = 1 ] && echo "Basics ready. Optional: --setup-truehd (TrueHD 96/192 kHz), --setup-stems (AI stems mode)."
  [ $ok = 1 ]
}

# ------------------------------------------------------------------ setup: TrueHD
setup_truehd() {
  local work need=() t
  echo "flac2awesome $VERSION: building the patched FFmpeg for TrueHD at 96/192 kHz"
  for t in git gcc make nasm pkg-config; do command -v "$t" >/dev/null || need+=("$t"); done
  if [ ${#need[@]} -gt 0 ]; then
    install_needs "Building needs: ${need[*]}" build || die "the build tools are required for --setup-truehd"
    hash -r
  fi
  [ "${F2A_DRY_RUN:-}" = 1 ] && { echo "  (dry run: would now download, patch and build FFmpeg)"; return 0; }
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  echo "Fetching FFmpeg source (${FFMPEG_COMMIT:0:7})..."
  git init -q "$work/ffmpeg"
  ( cd "$work/ffmpeg"
    git remote add origin https://github.com/FFmpeg/FFmpeg.git
    git fetch -q --depth 1 origin "$FFMPEG_COMMIT"
    git checkout -q FETCH_HEAD
    git apply - <<'PATCH_EOF'
diff --git a/libavcodec/mlpenc.c b/libavcodec/mlpenc.c
index ceeedb0..b761c42 100644
--- a/libavcodec/mlpenc.c
+++ b/libavcodec/mlpenc.c
@@ -135,6 +135,7 @@ typedef struct MLPEncodeContext {
     AVCodecContext *avctx;

     int             max_restart_interval;   ///< Max interval of access units in between two major frames.
+    int             peak_bitrate;           ///< Peak bitrate (bits/s) signalled in the major sync; 0 = automatic.
     int             min_restart_interval;   ///< Min interval of access units in between two major frames.
     int             cur_restart_interval;
     int             lpc_coeff_precision;
@@ -525,7 +526,14 @@ static av_cold int mlp_encode_init(AVCodecContext *avctx)
     }
     ctx->coded_sample_rate[1] = -1 & 0xf;

-    ctx->coded_peak_bitrate = mlp_peak_bitrate(9600000, avctx->sample_rate);
+    /* The major sync header promises that no access unit exceeds this rate;
+     * hardware decoders size their input buffering from it. A fixed 9.6 Mbps
+     * is exceeded by high sample rate multichannel streams (e.g. 96 kHz 5.1
+     * 24-bit), which makes hardware playback stutter. Default to the TrueHD
+     * maximum of 18 Mbps (MLP/DVD-Audio keeps 9.6 Mbps). */
+    if (!ctx->peak_bitrate)
+        ctx->peak_bitrate = avctx->codec_id == AV_CODEC_ID_TRUEHD ? 18000000 : 9600000;
+    ctx->coded_peak_bitrate = mlp_peak_bitrate(ctx->peak_bitrate, avctx->sample_rate);

     ctx->substream_info |= SUBSTREAM_INFO_ALWAYS_SET;
     if (avctx->ch_layout.nb_channels <= 2)
@@ -2269,6 +2277,7 @@ static av_cold int mlp_encode_close(AVCodecContext *avctx)
 #define OFFSET(x) offsetof(MLPEncodeContext, x)
 static const AVOption mlp_options[] = {
 { "max_interval", "Max number of frames between each new header", OFFSET(max_restart_interval),  AV_OPT_TYPE_INT, {.i64 = 16 }, MIN_HEADER_INTERVAL, MAX_HEADER_INTERVAL, FLAGS },
+{ "peak_bitrate", "Peak bitrate in bits/s signalled in the stream (0 = automatic)", OFFSET(peak_bitrate), AV_OPT_TYPE_INT, {.i64 = 0 }, 0, 100000000, FLAGS },
 { "lpc_coeff_precision", "LPC coefficient precision", OFFSET(lpc_coeff_precision), AV_OPT_TYPE_INT, {.i64 = 15 }, 0, 15, FLAGS },
 { "lpc_type", "LPC algorithm", OFFSET(lpc_type), AV_OPT_TYPE_INT, {.i64 = FF_LPC_TYPE_LEVINSON }, FF_LPC_TYPE_LEVINSON, FF_LPC_TYPE_CHOLESKY, FLAGS, .unit = "lpc_type" },
 { "levinson", NULL, 0, AV_OPT_TYPE_CONST, {.i64 = FF_LPC_TYPE_LEVINSON }, 0, 0, FLAGS, .unit = "lpc_type" },
PATCH_EOF
    echo "Patch applied. Configuring..."
    ./configure --prefix="$HOME/.local" --progs-suffix=-truehd \
      --disable-everything --disable-doc --disable-network --disable-autodetect \
      --disable-ffplay --disable-ffprobe --enable-ffmpeg --enable-avfilter --enable-swresample \
      --enable-encoder=truehd,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le \
      --enable-decoder=truehd,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le \
      --enable-muxer=mp4,mov,truehd,wav,spdif,null,pcm_f32le,pcm_s32le \
      --enable-demuxer=flac,wav,truehd,mov,pcm_f32le,pcm_s32le \
      --enable-parser=mlp,flac \
      --enable-filter=aresample,aformat,anull,pan,lowpass,highpass,equalizer,volume \
      --enable-protocol=file,pipe >"$work/configure.log" 2>&1 \
      || { tail -20 "$work/configure.log"; exit 1; }
    echo "Building (about a minute)..."
    make -j"$(nproc)" >"$work/build.log" 2>&1 || { tail -30 "$work/build.log"; exit 1; }
    mkdir -p "$(dirname "$TRUEHD_BIN")"
    install -m 755 ffmpeg-truehd "$TRUEHD_BIN"
  ) || die "building the patched FFmpeg failed"
  if "$TRUEHD_BIN" -hide_banner -h encoder=truehd 2>/dev/null | grep -q peak_bitrate; then
    echo "OK: installed $TRUEHD_BIN (patched TrueHD encoder: 48/96/192 kHz)"
  else
    die "build finished but the patched encoder option is missing"
  fi
}

# ------------------------------------------------------------------ setup: stems
setup_stems() {
  echo "flac2awesome $VERSION: installing the AI stems mode (PyTorch + Demucs)"
  ensure_python || die "Python 3 is required for --setup-stems"
  if ! python3 -c "import venv, ensurepip" 2>/dev/null; then
    install_needs "Python's venv module is missing" venv || die "the venv module is required"
  fi
  local index="cpu"
  if [ "${F2A_DRY_RUN:-}" = 1 ]; then
    command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1 && index="cu128"
    echo "  (dry run: would create $STEMS_VENV and install torch ($index), demucs, numpy)"; return 0
  fi
  if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then index="cu128"; fi
  echo "Creating $STEMS_VENV"
  mkdir -p "$DATA_DIR"
  python3 -m venv "$STEMS_VENV"
  "$STEMS_VENV/bin/python" -m pip install -q --upgrade pip || true
  echo "Installing PyTorch ($index build; several GB, this takes a while)..."
  "$STEMS_VENV/bin/python" -m pip install torch torchaudio \
      --index-url "https://download.pytorch.org/whl/$index" \
    || die "PyTorch installation failed. Check your internet connection; if it works, your Python
($(python3 --version 2>&1)) may be too new for the current PyTorch builds."
  echo "Installing Demucs..."
  "$STEMS_VENV/bin/python" -m pip install demucs numpy || die "Demucs installation failed"
  echo "Downloading the Demucs model (htdemucs_6s)..."
  "$STEMS_VENV/bin/python" -c "from demucs.pretrained import get_model; get_model('htdemucs_6s')" \
    || die "downloading the Demucs model failed"
  "$STEMS_VENV/bin/python" - <<'PY'
import torch
gpu = torch.cuda.is_available()
print("OK: stems mode ready (%s)" % (("GPU: " + torch.cuda.get_device_name(0)) if gpu else "CPU"))
PY
  echo "Note: the Demucs model weights are provided by Meta for research purposes; check their"
  echo "terms before any commercial use. You can remove stems mode with: rm -rf \"$STEMS_VENV\""
}

stems_python() {   # prints a python with torch + demucs + numpy, or nothing
  if [ -x "$STEMS_VENV/bin/python" ] && "$STEMS_VENV/bin/python" -c "import torch, demucs, numpy" 2>/dev/null; then
    echo "$STEMS_VENV/bin/python"
  elif python3 -c "import torch, demucs, numpy" 2>/dev/null; then
    echo python3
  fi
}

truehd_binary() {   # prints the TrueHD ffmpeg to use
  if [ -n "${THD_FFMPEG:-}" ]; then echo "$THD_FFMPEG"
  elif command -v ffmpeg-truehd >/dev/null; then echo ffmpeg-truehd
  elif [ -x "$TRUEHD_BIN" ]; then echo "$TRUEHD_BIN"
  else echo ffmpeg; fi
}

check_system() {
  local yes="yes" no="no"
  echo "flac2awesome $VERSION"
  printf "  %-34s %s\n" "ffmpeg / ffprobe" "$(command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null && echo $yes || echo "$no (required: run --setup)")"
  printf "  %-34s %s\n" "python3" "$(command -v python3 >/dev/null && echo $yes || echo "$no (required)")"
  local enc="" miss="no (needs FFmpeg)"
  if command -v ffmpeg >/dev/null; then enc="$(ffmpeg -hide_banner -encoders 2>/dev/null)"; miss="no"; fi
  case "$enc" in *" dca "*) printf "  %-34s %s\n" "DTS output" "$yes";;
    *) [ -n "$enc" ] && printf "  %-34s %s\n" "DTS output" "no (FFmpeg lacks the dca encoder)" \
         || printf "  %-34s %s\n" "DTS output" "$miss";; esac
  case "$enc" in *" flac "*) printf "  %-34s %s\n" "6-channel FLAC output" "$yes";; *) printf "  %-34s %s\n" "6-channel FLAC output" "$miss";; esac
  local tb; tb="$(truehd_binary)"
  case "$("$tb" -hide_banner -h encoder=truehd 2>/dev/null)" in
    *peak_bitrate*) printf "  %-34s %s\n" "TrueHD output" "yes, up to 192 kHz ($tb)";;
    *"truehd"*)     printf "  %-34s %s\n" "TrueHD output" "48 kHz only (run --setup-truehd for 96/192 kHz)";;
    *)              printf "  %-34s %s\n" "TrueHD output" "$miss";;
  esac
  python3 -c "import numpy" 2>/dev/null && printf "  %-34s %s\n" "smart upmix (numpy)" "$yes" \
    || printf "  %-34s %s\n" "smart upmix (numpy)" "no (run --setup)"
  if [ -n "$(stems_python)" ]; then printf "  %-34s %s\n" "stems upmix (PyTorch + Demucs)" "$yes"
  else printf "  %-34s %s\n" "stems upmix (PyTorch + Demucs)" "no (run --setup-stems)"; fi
  if [ "$DISTRO_FAMILY" != unknown ]; then
    printf "  %-34s %s\n" "distribution" "$DISTRO_ID ($DISTRO_FAMILY family)"
  fi
  return 0
}

# ------------------------------------------------------------------ options
OUTDIR="output"
files=()
need_arg() { [ $# -ge 2 ] && [ -n "$2" ] || die "option $1 needs a value (see --help)"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)       usage; exit 0 ;;
    -V|--version)    echo "flac2awesome $VERSION"; exit 0 ;;
    --check)         check_system; exit 0 ;;
    --setup)         setup_base; exit $? ;;
    --setup-truehd)  ensure_ffmpeg truehd || true; setup_truehd; exit 0 ;;
    --setup-stems)   setup_stems; exit 0 ;;
    --setup-all)     setup_base || die "basic setup incomplete"; setup_truehd; setup_stems
                     echo; [ "${F2A_DRY_RUN:-}" = 1 ] && { echo "(dry run: nothing was installed)"; exit 0; }
                     check_system; exit 0 ;;
    -o|--output)     need_arg "$@"; OUTPUT="$2"; shift 2 ;;
    -d|--outdir)     need_arg "$@"; OUTDIR="$2"; shift 2 ;;
    -u|--upmix)      need_arg "$@"; DTS_UPMIX="$2"; shift 2 ;;
    --lfe)           need_arg "$@"; DTS_LFE="$2"; shift 2 ;;
    --lfe-hz)        need_arg "$@"; DTS_LFE_HZ="$2"; shift 2 ;;
    --spread)        need_arg "$@"; DTS_SPREAD="$2"; shift 2 ;;
    --surround)      need_arg "$@"; DTS_SURROUND="$2"; shift 2 ;;
    --center)        need_arg "$@"; DTS_CENTER="$2"; shift 2 ;;
    --stems-mode)    need_arg "$@"; DTS_STEMS_MODE="$2"; shift 2 ;;
    --turn-bars)     need_arg "$@"; DTS_TURN_BARS="$2"; shift 2 ;;
    --stems-dir)     need_arg "$@"; DTS_STEMS_DIR="$2"; shift 2 ;;
    --max-abits)     need_arg "$@"; DTS_MAXABITS="$2"; shift 2 ;;
    --leadin)        need_arg "$@"; DTS_LEADIN="$2"; shift 2 ;;
    --thd-over)      need_arg "$@"; THD_OVER="$2"; shift 2 ;;
    --thd-peak)      need_arg "$@"; THD_PEAK="$2"; shift 2 ;;
    --thd-ffmpeg)    need_arg "$@"; THD_FFMPEG="$2"; shift 2 ;;
    --solo)          need_arg "$@"; DTS_SOLO="$2"; shift 2 ;;
    --)              shift; files+=("$@"); break ;;
    -*)              die "unknown option: $1 (see --help)" ;;
    *)               files+=("$1"); shift ;;
  esac
done

export OUTPUT="${OUTPUT:-dts}"
export DTS_UPMIX="${DTS_UPMIX:-simple}"
export DTS_LFE="${DTS_LFE:-on}"
export DTS_LFE_HZ="${DTS_LFE_HZ:-120}"
export DTS_SPREAD="${DTS_SPREAD:-0.6}"
export DTS_SURROUND="${DTS_SURROUND:-3}"
export DTS_CENTER="${DTS_CENTER:-0.8}"
export DTS_STEMS_MODE="${DTS_STEMS_MODE:-circle}"
export DTS_TURN_BARS="${DTS_TURN_BARS:-8}"
export DTS_MAXABITS="${DTS_MAXABITS:-14}"
export DTS_LEADIN="${DTS_LEADIN:-0}"
export DTS_SOLO="${DTS_SOLO:-}"
export THD_OVER="${THD_OVER:-ask}"
[ -n "${DTS_STEMS_DIR:-}" ] && export DTS_STEMS_DIR
[ -n "${THD_PEAK:-}" ] && export THD_PEAK

is_num() { [[ "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "$1 must be a number (got: $2)"; }
case "$OUTPUT" in dts|truehd|flac) ;; *) die "--output must be dts, truehd or flac (got: $OUTPUT)" ;; esac
case "$DTS_UPMIX" in simple|smart|stems) ;; *) die "--upmix must be simple, smart or stems (got: $DTS_UPMIX)" ;; esac
case "$DTS_LFE" in on|off) ;; *) die "--lfe must be on or off (got: $DTS_LFE)" ;; esac
case "$DTS_STEMS_MODE" in circle|glide|placed) ;; *) die "--stems-mode must be circle, glide or placed (got: $DTS_STEMS_MODE)" ;; esac
case "$THD_OVER" in ask|keep|spec) ;; *) die "--thd-over must be ask, keep or spec (got: $THD_OVER)" ;; esac
case "$DTS_SOLO" in ""|surround) ;; *) die "--solo must be surround (got: $DTS_SOLO)" ;; esac
is_num --lfe-hz "$DTS_LFE_HZ"; is_num --spread "$DTS_SPREAD"; is_num --center "$DTS_CENTER"
is_num --turn-bars "$DTS_TURN_BARS"; is_num --max-abits "$DTS_MAXABITS"; is_num --leadin "$DTS_LEADIN"
[[ "$DTS_SURROUND" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || die "--surround must be a number (got: $DTS_SURROUND)"
[ -z "${THD_PEAK:-}" ] || is_num --thd-peak "$THD_PEAK"
[ -z "${DTS_STEMS_DIR:-}" ] || [ -d "$DTS_STEMS_DIR" ] || die "--stems-dir: folder not found: $DTS_STEMS_DIR"

# ------------------------------------------------------------------ requirements
# Check what this run needs; offer to install anything missing (see "dependencies" above).
ensure_python || die "Python 3 is required (run: $0 --setup)"
case "$OUTPUT" in
  dts)    ensure_ffmpeg dca  || die "cannot continue without a suitable FFmpeg (run: $0 --setup)" ;;
  flac)   ensure_ffmpeg flac || die "cannot continue without FFmpeg (run: $0 --setup)" ;;
  truehd) ensure_ffmpeg      || die "cannot continue without FFmpeg (run: $0 --setup)" ;;
esac
PY=python3
if [ "$DTS_UPMIX" = smart ] || { [ "$DTS_UPMIX" = stems ] && [ -n "${DTS_STEMS_DIR:-}" ]; }; then
  ensure_numpy || die "numpy is required for this upmix mode (run: $0 --setup)"
fi
if [ "$DTS_UPMIX" = stems ] && [ -z "${DTS_STEMS_DIR:-}" ]; then
  PY="$(stems_python)"
  if [ -z "$PY" ]; then
    echo "Stems mode needs PyTorch and Demucs (several GB, installed in their own folder)."
    if confirm "Install stems mode now?"; then setup_stems; PY="$(stems_python)"; fi
    [ -n "$PY" ] || die "stems mode is not installed (run: $0 --setup-stems)"
  fi
fi
if [ "$OUTPUT" = truehd ]; then
  THD_FFMPEG="$(truehd_binary)"
  command -v "$THD_FFMPEG" >/dev/null || [ -x "$THD_FFMPEG" ] || die "TrueHD: $THD_FFMPEG not found"
  case "$("$THD_FFMPEG" -hide_banner -encoders 2>/dev/null)" in
    *" truehd "*) ;;
    *) die "TrueHD: $THD_FFMPEG has no truehd encoder (run: $0 --setup)" ;;
  esac
  case "$("$THD_FFMPEG" -hide_banner -h encoder=truehd 2>/dev/null)" in
    *peak_bitrate*) THD_PATCHED=1 ;;
    *) THD_PATCHED=0 ;;
  esac
  export THD_FFMPEG THD_PATCHED
fi
[ "${F2A_DRY_RUN:-}" = 1 ] && { echo "(dry run: stopping before the conversion)"; exit 0; }

# ------------------------------------------------------------------ input files
if [ ${#files[@]} -eq 0 ]; then
  files=( *.flac )
  [ ${#files[@]} -gt 0 ] || die "no .flac files in this folder (or pass files as arguments; see --help)"
else
  for f in "${files[@]}"; do [ -f "$f" ] || die "file not found: $f"; done
fi

mkdir -p "$OUTDIR"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/upmix.py" <<'PYEOF'
"""Stereo -> 5.1 direct/ambient upmixer (STFT based).

upmix(src_path, dst_raw, sr, params, progress_cb) reads stereo audio via ffmpeg,
writes float32 interleaved 6-channel raw audio in 5.1(side) order:
FL FR FC LFE SL SR.
"""
import subprocess, numpy as np

N, HOP = 2048, 512

def upmix(src, dst, params, progress=None):
    cmax   = params.get("center", 0.8)     # share of centre-direction sound in the center speaker
    gf     = params.get("front_amb", 0.5)  # ambience kept in the front speakers
    gs     = params.get("rear_amb", 1.0)   # ambience sent to the surrounds
    tau    = params.get("tau", 0.04)       # smoothing time constant, seconds
    d_sl   = params.get("delay_l", 0.008)  # surround ambience delays, seconds
    d_sr   = params.get("delay_r", 0.011)
    lfe_g  = params.get("lfe", 0.5)
    fsm    = params.get("fsmooth", 3)      # frequency smoothing half-width, bins
    cbias  = params.get("cbias", 0.3)
    rg     = np.float32(10 ** (params.get("rear_db", 3.0) / 20))  # overall surround level trim
    spread = params.get("spread", 0.5)     # |pan| that maps to the surround speaker (smaller = wider)
    decor  = params.get("decor", False)    # random-phase decorrelation of surround ambience

    # --- read stereo float32 at source rate ---
    sr = int(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=sample_rate", "-of", "default=nw=1:nk=1", src],
            capture_output=True, text=True, check=True).stdout.split()[0])
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", src,
            "-map", "0:a:0", "-ac", "2", "-f", "f32le", "-"],
            capture_output=True, check=True).stdout
    x = np.frombuffer(raw, dtype="<f4").reshape(-1, 2)
    n = len(x)

    dl, dr = int(round(d_sl * sr)), int(round(d_sr * sr))
    pad = N
    xp = np.zeros((n + 2 * pad, 2), dtype=np.float32); xp[pad:pad + n] = x
    out = np.lib.format.open_memmap(dst + ".npy", mode="w+", dtype=np.float32,
                                    shape=(n + 2 * pad + max(dl, dr) + N, 6))

    win = np.sqrt(np.hanning(N + 1)[:N]).astype(np.float32)     # sqrt-Hann, WOLA
    olascale = 1.0 / (np.sum(win ** 2) / HOP)                    # = 0.5 at 75% overlap
    K = N // 2 + 1
    f = np.arange(K) * sr / N
    # low-frequency bypass: below ~100 Hz leave L/R untouched, full effect above ~200 Hz
    b = np.clip((f - 100.0) / 100.0, 0, 1); b = (b * b * (3 - 2 * b)).astype(np.float32)
    rng = np.random.default_rng(12345)
    ph_l = np.exp(1j * rng.uniform(-np.pi, np.pi, K)).astype(np.complex64)
    ph_r = np.exp(1j * rng.uniform(-np.pi, np.pi, K)).astype(np.complex64)
    ph_l[:4] = 1; ph_r[:4] = 1
    a = np.float32(np.exp(-HOP / (tau * sr)))
    eps = np.float32(1e-12)

    nframes = (len(xp) - N) // HOP + 1
    Sll = np.zeros(K, np.float32); Srr = np.zeros(K, np.float32); Slr = np.zeros(K, np.complex64)
    CH = 512
    for c0 in range(0, nframes, CH):
        c1 = min(nframes, c0 + CH)
        idx = (np.arange(c0, c1)[:, None] * HOP + np.arange(N)[None, :])
        L = np.fft.rfft(xp[idx, 0] * win, axis=1).astype(np.complex64)
        R = np.fft.rfft(xp[idx, 1] * win, axis=1).astype(np.complex64)
        F = c1 - c0
        Pll = np.empty((F, K), np.float32); Prr = np.empty((F, K), np.float32)
        Plr = np.empty((F, K), np.complex64)
        ll = (L.real ** 2 + L.imag ** 2); rr = (R.real ** 2 + R.imag ** 2); lr = L * np.conj(R)
        if fsm > 0:   # smooth the spectra across neighbouring frequencies (less estimation bias)
            ker = np.hanning(2 * fsm + 3)[1:-1].astype(np.float32); ker /= ker.sum()
            def fs(z):
                zp = np.concatenate([z[:, fsm:0:-1], z, z[:, -2:-fsm-2:-1]], axis=1)
                acc = np.zeros_like(z)
                for i, kv in enumerate(ker): acc += kv * zp[:, i:i + z.shape[1]]
                return acc
            ll = fs(ll); rr = fs(rr); lr = fs(lr)
        for t in range(F):
            Sll = a * Sll + (1 - a) * ll[t]; Srr = a * Srr + (1 - a) * rr[t]
            Slr = a * Slr + (1 - a) * lr[t]
            Pll[t] = Sll; Prr[t] = Srr; Plr[t] = Slr
        tot = Pll + Prr
        # coherence-bias correction: short averages make unrelated channels look partly
        # correlated; treat coherence below `cbias` as zero and rescale the rest
        mag = np.sqrt(Plr.real ** 2 + Plr.imag ** 2); geo = np.sqrt(Pll * Prr)
        coh = mag / (geo + eps)
        coh = np.clip((coh - cbias) / (1 - cbias), 0, 1)
        mag = coh * geo
        Pa = 0.5 * (tot - np.sqrt((Pll - Prr) ** 2 + 4 * mag ** 2))
        Pa = np.clip(Pa, 0, None)
        Pa = np.minimum(Pa, np.minimum(Pll, Prr))
        Psl = Pll - Pa; Psr = Prr - Pa
        dL = np.sqrt(Psl / (Pll + eps)); aL = np.sqrt(Pa / (Pll + eps))
        dR = np.sqrt(Psr / (Prr + eps)); aR = np.sqrt(Pa / (Prr + eps))
        pan = (Psr - Psl) / (Psr + Psl + eps)
        DL = dL * L; DR = dR * R
        AL = aL * L; AR = aR * R
        # one direct signal per bin: phase of L+R, energy of both direct parts
        S = DL + DR
        e_d = (np.abs(DL) ** 2 + np.abs(DR) ** 2)
        e_s = np.abs(S) ** 2
        D = S * np.sqrt(np.minimum(e_d / (e_s + eps), 4.0))
        # stereo position -> direction: |pan| = spread -> 110 deg (surround speaker)
        ang = 110.0 * np.clip(np.abs(pan) / spread, 0, 1)
        f1 = np.clip(ang / 30.0, 0, 1)                    # centre -> front pair
        f2 = np.clip((ang - 30.0) / 80.0, 0, 1)           # front -> surround pair
        g_c = np.cos(f1 * np.pi / 2)
        g_f = np.where(ang <= 30, np.sin(f1 * np.pi / 2), np.cos(f2 * np.pi / 2))
        g_s = np.where(ang <= 30, 0.0, np.sin(f2 * np.pi / 2)).astype(np.float32)
        # centre share kept in the centre speaker; the rest goes equally to front L/R
        g_cc = g_c * np.sqrt(cmax)
        g_cs = g_c * np.sqrt((1 - cmax) / 2)
        left = (pan <= 0); right = ~left
        FC = b * g_cc * D
        FLd = (g_cs + left * g_f) * D
        FRd = (g_cs + right * g_f) * D
        SLd = (left * g_s) * D
        SRd = (right * g_s) * D
        FL = (1 - b) * L + b * (FLd + gf * AL)
        FR = (1 - b) * R + b * (FRd + gf * AR)
        SLd = b * SLd; SRd = b * SRd
        SL = b * gs * AL * (ph_l if decor else 1)
        SR = b * gs * AR * (ph_r if decor else 1)
        SL = rg * SL; SR = rg * SR; SLd = rg * SLd; SRd = rg * SRd
        for ch, Y, d in ((0, FL, 0), (1, FR, 0), (2, FC, 0), (4, SL, dl), (5, SR, dr),
                         (4, SLd, 0), (5, SRd, 0)):
            y = np.fft.irfft(Y, n=N, axis=1).astype(np.float32) * win * olascale
            for t in range(F):
                s = (c0 + t) * HOP + d
                out[s:s + N, ch] += y[t]
        if progress: progress(c1 / nframes)

    res = out[pad:pad + n]
    # LFE: (L+R)/2, low-passed by ffmpeg later
    res[:, 3] = lfe_g * (x[:, 0] + x[:, 1])
    res.tofile(dst)
    del out
    import os; os.remove(dst + ".npy")
    return sr, n
PYEOF

cat > "$tmp/stems.py" <<'PYEOF'
"""Stems upmix: Demucs separation + placement/motion around a 5.1 layout.

stems_upmix(src, dst, opts, progress) writes float32 interleaved 6-channel raw audio
(5.1(side) order FL FR FC LFE SL SR) at 44.1 kHz and returns (44100, n).
"""
import os, subprocess
import numpy as np

SR = 44100
NAMES = ["drums", "bass", "other", "vocals", "guitar", "piano"]
SPK = [(0.0, 2), (30.0, 1), (110.0, 5), (250.0, 4), (330.0, 0)]   # (angle, channel)

def read_audio(path):
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path,
                          "-map", "0:a:0", "-ac", "2", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype="<f4").reshape(-1, 2)

# ---------------------------------------------------------------- separation
def separate(mix, workdir, progress=None):
    """returns dict name -> (n, 2) float32 using Demucs (GPU if available)."""
    stems_dir = os.environ.get("DTS_STEMS_DIR")
    if stems_dir:                       # use ready-made stems: <dir>/<name>.flac
        out = {}
        for k in NAMES:
            p = os.path.join(stems_dir, k + ".flac")
            out[k] = read_audio(p) if os.path.exists(p) else np.zeros_like(mix)
        return out
    import torch
    from demucs.pretrained import get_model
    from demucs.apply import apply_model
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = get_model(os.environ.get("DEMUCS_MODEL", "htdemucs_6s"))
    model.eval()
    wav = torch.from_numpy(np.ascontiguousarray(mix.T))
    ref = wav.mean(0); mean, std = ref.mean(), ref.std() + 1e-8
    with torch.no_grad():
        res = apply_model(model, ((wav - mean) / std)[None], device=device,
                          shifts=1, split=True, overlap=0.25, progress=False)[0]
    res = (res * std + mean).cpu().numpy()
    del wav
    if device == "cuda":
        torch.cuda.empty_cache()
    return {k: np.ascontiguousarray(res[i].T, dtype=np.float32) for i, k in enumerate(model.sources)}

# ---------------------------------------------------------------- panning
def pan_gains(theta):
    th = np.mod(theta, 360.0)
    g = np.zeros((len(th), 6), np.float32)
    angs = [a for a, _ in SPK] + [360.0]
    chs = [c for _, c in SPK] + [SPK[0][1]]
    for i in range(len(SPK)):
        a0, a1 = angs[i], angs[i + 1]
        m = (th >= a0) & (th < a1)
        if not m.any(): continue
        f = (th[m] - a0) / (a1 - a0)
        g[m, chs[i]] += np.cos(f * np.pi / 2)
        g[m, chs[i + 1]] += np.sin(f * np.pi / 2)
    return g

def place(stereo, theta_l, theta_r):
    return stereo[:, :1] * pan_gains(theta_l) + stereo[:, 1:2] * pan_gains(theta_r)

def beat_grid(drums):
    hop = 512
    x = drums.mean(1)
    n = len(x) // hop
    if n < 64:
        return 120.0, 0.0
    fr = x[:n * hop].reshape(n, hop)
    spec = np.abs(np.fft.rfft(fr * np.hanning(hop), axis=1))
    flux = np.maximum(np.diff(np.log1p(spec * 100), axis=0), 0).sum(1)
    flux = np.concatenate([[0], flux]); flux -= flux.mean()
    fps = SR / hop
    best = (-np.inf, 120.0)
    for bpm in np.arange(70, 180, 0.25):
        lag = 60 * fps / bpm
        score = 0
        for k in range(1, 5):
            L = int(round(lag * k))
            if L >= n - 1: break
            score += np.dot(flux[:-L], flux[L:]) / (n - L)
        best = max(best, (score, bpm))
    bpm = best[1]
    period = 60 * fps / bpm
    phases = np.arange(0, period, 0.5)
    sc = [flux[np.round(np.arange(p, n - 1, period)).astype(int)].sum() for p in phases]
    return bpm, phases[int(np.argmax(sc))] / fps

# ---------------------------------------------------------------- layout
def angles(mode, tb, bar, o):
    """per-sample angles for (guitar L, guitar R, other L, other R, piano L, piano R)."""
    z = np.zeros_like(tb); w = o["width"] / 2
    if mode == "placed":
        return z - 110, z + 110, z - 80, z + 80, z - 60, z + 60
    if mode == "glide":
        ph = np.mod(tb, 2 * o["bars"] * bar) / (o["bars"] * bar)
        tri = np.where(ph < 1, ph, 2 - ph)
        c = 250 - 140 * (0.5 - 0.5 * np.cos(np.pi * tri))   # SL -> behind -> SR and back
        return c + w, c - w, 360 - c - w, 360 - c + w, z - 60, z + 60
    if mode == "circle":
        rot = 360 * tb / (o["turn_bars"] * bar)
        return rot - w, rot + w, 180 - rot - w, 180 - rot + w, z - 60, z + 60
    raise ValueError("unknown stems mode: %s" % mode)

def stems_upmix(src, dst, opts, progress=None):
    o = dict(mode="circle", turn_bars=8.0, bars=2.0, width=30.0, anchor=18.0, lfe=0.5)
    o.update({k: v for k, v in opts.items() if v is not None})
    mix = read_audio(src)
    n = len(mix)
    if progress: progress(0.02, "separating")
    S = separate(mix, os.path.dirname(dst), progress)
    for k in NAMES:
        v = S.get(k, np.zeros((n, 2), np.float32))
        if len(v) < n: v = np.concatenate([v, np.zeros((n - len(v), 2), np.float32)])
        S[k] = v[:n].astype(np.float32)
    if progress: progress(0.75, "placing")
    bpm, off = beat_grid(S["drums"])
    bar = 4 * 60.0 / bpm
    out = np.lib.format.open_memmap(dst + ".npy", mode="w+", dtype=np.float32, shape=(n, 6))
    B = SR * 10
    a = o["anchor"]
    for s0 in range(0, n, B):
        s1 = min(n, s0 + B)
        z = np.zeros(s1 - s0)
        tb = np.arange(s0, s1) / SR - off
        blk = {k: S[k][s0:s1] for k in NAMES}
        m = mix[s0:s1]
        resid = m - sum(blk.values())
        y = place(blk["vocals"], z - 12, z + 12)
        y += place(blk["drums"], z - a, z + a)
        y += place(blk["bass"], z - a, z + a)
        y += place(resid, z - 30, z + 30)
        gl, gr, ol, orr, pl, pr = angles(o["mode"], tb, bar, o)
        y += place(blk["guitar"], gl, gr)
        y += place(blk["other"], ol, orr)
        y += place(blk["piano"], pl, pr)
        y[:, 3] = o["lfe"] * (m[:, 0] + m[:, 1])
        out[s0:s1] = y
        if progress: progress(0.75 + 0.25 * s1 / n, "placing")
    out.flush()
    np.asarray(out).tofile(dst)
    del out
    os.remove(dst + ".npy")
    return SR, n, bpm
PYEOF

cat > "$tmp/dtswav.py" <<'PYEOF'
import os, sys, struct, subprocess, time

src, dst, workdir = sys.argv[1], sys.argv[2], sys.argv[3]
lfe     = os.environ.get("DTS_LFE", "on") != "off"
leadin  = float(os.environ.get("DTS_LEADIN", "0"))
maxab   = int(os.environ.get("DTS_MAXABITS", "14"))
umode   = os.environ.get("DTS_UPMIX", "simple")
lfe_hz  = float(os.environ.get("DTS_LFE_HZ", "120"))
# LFE: everything below lfe_hz, 4th-order (24 dB/octave) low-pass
LFE_LP  = "lowpass=f=%g:p=2:c=LFE,lowpass=f=%g:p=2:c=LFE" % (lfe_hz, lfe_hz)
smart   = umode == "smart"
stemsm  = umode == "stems"
thd     = os.environ.get("OUTPUT", "dts") == "truehd"
flacout = os.environ.get("OUTPUT", "dts") == "flac"
THD_FF  = os.environ.get("THD_FFMPEG", "ffmpeg")
THD_PATCHED = os.environ.get("THD_PATCHED", "0") == "1"
solo    = os.environ.get("DTS_SOLO", "") == "surround"
SOLO    = ["pan=5.1(side)|FL=0*FL|FR=0*FR|FC=0*FC|LFE=0*LFE|SL=SL|SR=SR"] if solo else []

FRAME  = 1792                      # bytes per DTS-CD frame at 1234.8 kbps, 512 samples
LADDER = [1234800, 1152000, 1024000, 960000, 896000, 768000, 640000]
# Simple upmix: FL=L FR=R FC=(L+R)/2 LFE=(L+R)/2 low-passed, surrounds swapped (SL=R, SR=L)
UPMIX  = "pan=5.1(side)|FL=c0|FR=c1|FC=0.5*c0+0.5*c1|LFE=0.5*c0+0.5*c1|SL=c1|SR=c0," + LFE_LP
TO50   = "pan=5.0(side)|FL=FL|FR=FR|FC=FC|SL=SL|SR=SR"
RESAMP = "aresample=44100:filter_size=64:phase_shift=10:cutoff=0.97"
AF     = ",".join([UPMIX] + SOLO + ([] if lfe else [TO50]) + [RESAMP])
# progress bar: [0, UP_END) upmix, [UP_END, ENC_END) encoding, rest packing
UP_END  = 0.10 if smart else 0.50 if stemsm else 0.0
if thd or flacout:
    UP_END = 0.25 if smart else 0.60 if stemsm else 0.0
ENC_END = 0.75

t0 = time.time()
is_tty = sys.stderr.isatty()

def fmt(sec):
    sec = int(round(sec)); m, s = divmod(sec, 60); h, m = divmod(m, 60)
    return "%d:%02d:%02d" % (h, m, s) if h else "%d:%02d" % (m, s)

last_draw = [0.0]
def progress(frac, what, force=False):
    now = time.time()
    if not force and now - last_draw[0] < 0.25: return
    last_draw[0] = now
    frac = max(0.0, min(frac, 1.0))
    el = now - t0
    width = 30; full = int(frac * width)
    line = "   [%s%s] %3d%%  %-10s elapsed %s" % (
        "#" * full, "-" * (width - full), int(frac * 100), what, fmt(el))
    if is_tty:
        sys.stderr.write("\r" + line + "\033[K"); sys.stderr.flush()

# --- duration (for encode progress) ---
try:
    dur = float(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0",
        "-show_entries", "stream=duration:format=duration", "-of", "default=nw=1:nk=1", src],
        capture_output=True, text=True).stdout.split()[0])
except Exception:
    dur = 0.0

# --- 0) smart upmix to a 6-channel float file (FL FR FC LFE SL SR) ---
SRC_IN = ["-i", src]
if smart:
    from upmix import upmix
    upraw = os.path.join(workdir, "up.raw")
    sr_in, n_in = upmix(src, upraw, {"rear_db": float(os.environ.get("DTS_SURROUND", "3")),
                                     "spread": float(os.environ.get("DTS_SPREAD", "0.6")),
                                     "center": float(os.environ.get("DTS_CENTER", "0.8")),
                                     "tau": 0.05, "cbias": 0.3},
                        lambda fr: progress(UP_END * fr, "upmixing"))
    dur = n_in / sr_in
    SRC_IN = ["-f", "f32le", "-ar", str(sr_in), "-ch_layout", "5.1(side)", "-i", upraw]
    AF = ",".join([LFE_LP] + SOLO + ([] if lfe else [TO50]) + [RESAMP])

bpm = None
if stemsm:
    from stems import stems_upmix
    upraw = os.path.join(workdir, "up.raw")
    sr_in, n_in, bpm = stems_upmix(src, upraw,
                                   {"mode": os.environ.get("DTS_STEMS_MODE", "circle"),
                                    "turn_bars": float(os.environ.get("DTS_TURN_BARS", "8"))},
                                   lambda fr, what: progress(UP_END * fr, what, force=True))
    dur = n_in / sr_in
    SRC_IN = ["-f", "f32le", "-ar", str(sr_in), "-ch_layout", "5.1(side)", "-i", upraw]
    AF = ",".join([LFE_LP] + SOLO + ([] if lfe else [TO50]) + [RESAMP])

# --- 6-channel FLAC output: lossless, source sample rate, then done ---
if flacout:
    base = [LFE_LP] if (smart or stemsm) else [UPMIX]   # UPMIX already ends with LFE_LP
    af = ",".join(base + SOLO + ([] if lfe else [TO50]) + ["aformat=sample_fmts=s32"])
    prog = os.path.join(workdir, "prog_flac.txt")
    cmd = (["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostats", "-y", "-progress", prog]
           + SRC_IN + ["-i", src, "-map", "0:a:0", "-map", "1:v?", "-map_metadata", "1",
                       "-af", af, "-c:a", "flac", "-bits_per_raw_sample", "24",
                       "-compression_level", "8", "-c:v", "copy", "-disposition:v", "attached_pic",
                       "-f", "flac", dst])
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)
    def flac_done():
        try:
            txt = open(prog).read()
        except OSError:
            return 0.0
        for line in reversed(txt.splitlines()):
            if line.startswith("out_time_us="):
                try: return max(0, int(line.split("=")[1])) / 1e6
                except ValueError: return 0.0
        return 0.0
    while p.poll() is None:
        if dur > 0:
            progress(UP_END + (1 - UP_END) * min(1.0, flac_done() / dur), "encoding")
        time.sleep(0.2)
    if p.returncode != 0:
        if is_tty: sys.stderr.write("\n")
        sys.exit("FLAC encode failed")
    progress(1.0, "done", force=True)
    if is_tty: sys.stderr.write("\r\033[K"); sys.stderr.flush()
    try:
        info = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
                               "stream=sample_rate,channels", "-of", "default=nw=1:nk=1", dst],
                              capture_output=True, text=True).stdout.split()
        rate_o, ch_o = int(info[0]), int(info[1])
    except Exception:
        rate_o, ch_o = 0, 0
    size = os.path.getsize(dst)
    print("   FLAC: %g kHz / 24-bit, %d channels, %.1f MB, %.1f Mbps average"
          % (rate_o / 1000, ch_o, size / 1e6, size * 8 / max(dur, 1e-6) / 1e6))
    if bpm:
        print("   tempo: %.1f BPM" % bpm)
    print("   time: %s" % fmt(time.time() - t0))
    sys.exit(0)

# --- TrueHD output: one lossless encode, then done ---
if thd:
    def probe_rate(path):
        try:
            return int(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0",
                "-show_entries", "stream=sample_rate", "-of", "default=nw=1:nk=1", path],
                capture_output=True, text=True).stdout.split()[0])
        except Exception:
            return 48000
    have = sr_in if (smart or stemsm) else probe_rate(src)
    # hardware TrueHD uses the 48 kHz family (Blu-ray: 48/96/192 kHz)
    target = {44100: 48000, 88200: 96000, 176400: 192000}.get(have, have)
    if target not in (48000, 96000, 192000):
        target = 48000 if target < 72000 else 96000 if target < 144000 else 192000
    if not THD_PATCHED:
        target = 48000          # stock encoder: higher rates stutter on hardware decoders
    base = [LFE_LP] if (smart or stemsm) else [UPMIX]   # UPMIX already ends with LFE_LP
    thd_in = ["-i", src]
    if smart or stemsm:
        # hand the 6-channel upmix over as a WAV (the minimal patched build reads WAV, not raw)
        upwav = os.path.join(workdir, "up.wav")
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"] + SRC_IN +
                       ["-c:a", "pcm_f32le", upwav], check=True)
        os.remove(upraw)
        thd_in = ["-i", upwav]
    peak_opt = ["-peak_bitrate", os.environ["THD_PEAK"]] if (THD_PATCHED and os.environ.get("THD_PEAK")) else []

    def thd_encode(rate, label):
        rs = "aresample=%d:filter_size=64:phase_shift=10:cutoff=0.97" % rate
        af = ",".join(base + SOLO + ([] if lfe else [TO50]) + [rs, "aformat=sample_fmts=s32p"])
        prog = os.path.join(workdir, "prog_thd.txt")
        if os.path.exists(prog): os.remove(prog)
        if thd_in[-1].endswith("reduced.wav"):
            af = "anull"                 # already rendered at the target rate and requantized
        cmd = [THD_FF, "-hide_banner", "-loglevel", "error", "-nostats", "-y", "-progress", prog] \
              + thd_in + ["-i", src, "-map", "0:a:0", "-map_metadata", "1", "-af", af,
                          "-c:a", "truehd", "-strict", "-2"] + peak_opt + ["-f", "mp4", dst]
        p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)
        def thd_done():
            try:
                txt = open(prog).read()
            except OSError:
                return 0.0
            for line in reversed(txt.splitlines()):
                if line.startswith("out_time_us="):
                    try: return max(0, int(line.split("=")[1])) / 1e6
                    except ValueError: return 0.0
            return 0.0
        while p.poll() is None:
            if dur > 0:
                progress(UP_END + (1 - UP_END) * min(1.0, thd_done() / dur), label)
            time.sleep(0.2)
        if p.returncode != 0:
            if is_tty: sys.stderr.write("\n")
            sys.exit("TrueHD encode failed")

    def thd_peak_check():
        """(access units above the declared peak, max AU bitrate, declared peak) in bits/s"""
        raw = os.path.join(workdir, "check.thd")
        subprocess.run([THD_FF, "-hide_banner", "-loglevel", "error", "-y", "-i", dst,
                        "-map", "0:a:0", "-c", "copy", "-f", "truehd", raw], check=True)
        peakfield = None; prate = 48000; maxlen = 0; sizes = {}
        with open(raw, "rb") as f:          # walk the access units without loading the file
            while True:
                h = f.read(20)
                if len(h) < 4: break
                ln = (struct.unpack(">H", h[:2])[0] & 0xfff) * 2
                if ln == 0: break
                if peakfield is None and h[4:8] == b"\xf8\x72\x6f\xba":
                    rb = h[8] >> 4
                    prate = (48000 if rb < 8 else 44100) << (rb & 7)
                    peakfield = struct.unpack(">H", h[18:20])[0] & 0x7fff
                sizes[ln] = sizes.get(ln, 0) + 1
                f.seek(ln - len(h), 1)
        os.remove(raw)
        peak = ((peakfield or 0) * prate + 8) >> 4
        over = sum(cnt for ln, cnt in sizes.items() if ln * 8 * 1200 > peak)
        mx = max(sizes) * 8 * 1200 if sizes else 0
        return over, mx, peak

    SPEC = 18000000                 # TrueHD maximum peak data rate (Blu-ray)

    def requantize(src_wav, dst_wav, bits):
        """reduce a 32-bit PCM WAV to `bits` significant bits with TPDF dither (in chunks)"""
        import numpy as np
        with open(src_wav, "rb") as f:
            head = f.read(1 << 16)
        pos = 12
        while pos + 8 <= len(head):
            cid = head[pos:pos + 4]; csz = struct.unpack("<I", head[pos + 4:pos + 8])[0]
            if cid == b"data":
                break
            pos += 8 + csz + (csz & 1)
        data_off = pos + 8
        total = (os.path.getsize(src_wav) - data_off) // 4
        q = 1 << (32 - bits)
        rng = np.random.default_rng(1)
        with open(src_wav, "rb") as fi, open(dst_wav, "wb") as fo:
            fo.write(fi.read(data_off))
            CH = 1 << 22
            done = 0
            while done < total:
                n = min(CH, total - done)
                x = np.frombuffer(fi.read(n * 4), dtype="<i4").astype(np.int64)
                dith = (rng.integers(0, q, n) + rng.integers(0, q, n) - q)   # TPDF, +-1 LSB
                y = np.floor((x + dith) / q + 0.5).astype(np.int64) * q
                fo.write(np.clip(y, -(1 << 31), (1 << 31) - q).astype("<i4").tobytes())
                done += n

    def render_wav(rate, path):
        """the exact 24-bit 6-channel PCM the encoder would get, as a WAV"""
        rs = "aresample=%d:filter_size=64:phase_shift=10:cutoff=0.97" % rate
        af = ",".join(base + SOLO + ([] if lfe else [TO50]) + [rs, "aformat=sample_fmts=s32"])
        subprocess.run([THD_FF, "-hide_banner", "-loglevel", "error", "-y"] + thd_in +
                       ["-map", "0:a:0", "-af", af, "-c:a", "pcm_s32le", "-f", "wav", path],
                       check=True)

    def ask_over(rate, over, mx, limit, total_aus):
        choice = os.environ.get("THD_OVER", "ask")
        if is_tty: sys.stderr.write("\r\033[K"); sys.stderr.flush()
        keep_peak = (int(mx / 100000) + 2) * 100000      # real peak, rounded up + margin
        print("   WARNING: at %g kHz / 24-bit this song needs up to %.2f Mbps in %d places (%.3f%%),"
              % (rate / 1000, mx / 1e6, over, 100.0 * over / max(total_aus, 1)))
        print("   above the %.1f Mbps peak TrueHD allows. Lossless audio cannot be made smaller, and a"
              % (limit / 1e6))
        print("   decoder that trusts the declared peak may stutter in those places.")
        if choice in ("keep", "spec"):
            print("   THD_OVER=%s: %s" % (choice, "keeping maximum quality" if choice == "keep"
                                         else "staying within the spec"))
            return choice, keep_peak
        try:
            tin = open("/dev/tty", "r"); tty = open("/dev/tty", "w")
        except OSError:
            print("   (no terminal to ask; staying within the spec - set THD_OVER=keep to override)")
            return "spec", keep_peak
        if THD_PATCHED:
            tty.write("     1) Keep maximum quality: %g kHz / 24-bit, lossless. The file declares a\n"
                      "        %.1f Mbps peak, outside the TrueHD spec. Receivers that accept it play it\n"
                      "        perfectly (tested: Denon AVR-X2700H); receivers strictly limited to\n"
                      "        %.1f Mbps may stutter in those places.\n"
                      % (rate / 1000, keep_peak / 1e6, limit / 1e6))
        else:
            tty.write("     1) Keep as is: %g kHz / 24-bit (stock encoder: the declared peak cannot be\n"
                      "        raised, so playback may stutter in those places).\n" % (rate / 1000))
        tty.write("     2) Stay within the spec, lowering quality only as much as needed: first the\n"
                  "        lowest bits (24 -> 23-bit = 138 dB dynamic range, far beyond audibility),\n"
                  "        down to 20-bit; the sample rate only if that is not enough.\n")
        while True:
            tty.write("   Choice [1/2]: "); tty.flush()
            a = tin.readline().strip()
            if a in ("1", "2"):
                tin.close(); tty.close()
                return ("keep" if a == "1" else "spec"), keep_peak

    def count_aus():
        return int(dur * 1200)

    rate = target; bits = 24; notes = []
    thd_encode(rate, "encoding")
    over, mx, peak = thd_peak_check()
    if over:
        choice, keep_peak = ask_over(rate, over, mx, peak, count_aus())
        if choice == "keep" and THD_PATCHED:
            peak_opt = ["-peak_bitrate", str(keep_peak)]
            thd_encode(rate, "re-encoding")
            over, mx, peak = thd_peak_check()
            notes.append("kept %g kHz / 24-bit with a declared peak of %.1f Mbps (outside the "
                         "TrueHD spec of %.1f Mbps)" % (rate / 1000, peak / 1e6, SPEC / 1e6))
        elif choice == "keep":
            notes.append("kept as is: may stutter where the stream exceeds %.1f Mbps" % (peak / 1e6))
        else:
            first_over, first_mx = over, mx
            full = os.path.join(workdir, "full.wav"); red = os.path.join(workdir, "reduced.wav")
            saved_in = thd_in
            while over:
                if bits > 20:
                    bits -= 1
                else:
                    if rate <= 48000:
                        break
                    rate //= 2; bits = 24
                    thd_in = saved_in
                if bits == 24:
                    thd_encode(rate, "re-encoding")
                else:
                    if not os.path.exists(full) or bits == 23:
                        progress(UP_END, "rendering", force=True)
                        thd_in = saved_in
                        render_wav(rate, full)
                    progress(UP_END, "%d-bit" % bits, force=True)
                    requantize(full, red, bits)
                    thd_in = ["-i", red]
                    thd_encode(rate, "%d-bit" % bits)
                over, mx, peak = thd_peak_check()
            thd_in = saved_in
            for f_ in (full, red):
                if os.path.exists(f_): os.remove(f_)
            if over:
                notes.append("warning: %d access units still exceed %.1f Mbps even at 48 kHz / 20-bit"
                             % (over, peak / 1e6))
            else:
                notes.append("reduced from %g kHz / 24-bit to %g kHz / %d-bit to stay within the "
                             "%.1f Mbps TrueHD peak (was up to %.2f Mbps in %d places)"
                             % (target / 1000, rate / 1000, bits, peak / 1e6, first_mx / 1e6, first_over))
    progress(1.0, "done", force=True)
    if is_tty: sys.stderr.write("\r\033[K"); sys.stderr.flush()
    size = os.path.getsize(dst)
    note = "" if rate == have else "  (resampled from %g kHz)" % (have / 1000)
    print("   TrueHD: %g kHz / %d-bit, %.1f MB, %.1f Mbps average, peak %.1f of %.1f Mbps%s"
          % (rate / 1000, bits, size / 1e6, size * 8 / max(dur, 1e-6) / 1e6, mx / 1e6, peak / 1e6, note))
    for n_ in notes:
        print("   " + n_)
    if bpm:
        print("   tempo: %.1f BPM" % bpm)
    print("   time: %s" % fmt(time.time() - t0))
    sys.exit(0)

# --- 1) encode every bitrate of the ladder, in parallel (one per CPU core) ---
# FFmpeg bug: for 5.1 its encoder fills the LFE filter history from the SR channel.
# Workaround: one extra encode ("LFE job") whose SR input carries the LFE signal; its
# 72 bits of LFE data per frame are copied into the final frames.
LFEJOB = 0
# DTS's LFE coding path (64x decimation + interpolation) rolls off from ~30 Hz (-6 dB at 80 Hz,
# -14 dB at 120 Hz, measured). Two peaking EQs invert that within 0.3 dB, applied only in the
# LFE job, so the decoded LFE follows the intended DTS_LFE_HZ low-pass.
LFE_EQ = ("equalizer=f=131.3:t=q:w=2.345:g=11.2:c=LFE,"
          "equalizer=f=106.0:t=q:w=0.779:g=4.97:c=LFE,")
AF_LFE = AF.replace(RESAMP, LFE_EQ + "pan=5.1(side)|FL=FL|FR=FR|FC=FC|LFE=LFE|SL=SL|SR=LFE," + RESAMP)
def start(br):
    out  = os.path.join(workdir, "core_%d.dts" % br)
    prog = os.path.join(workdir, "prog_%d.txt" % br)
    af, rate = (AF_LFE, LADDER[0]) if br == LFEJOB else (AF, br)
    p = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostats", "-y",
                          "-progress", prog] + SRC_IN + ["-af", af,
                          "-c:a", "dca", "-strict", "-2", "-b:a", str(rate), "-f", "dts", out],
                         stdin=subprocess.DEVNULL)
    return p, prog

def done_seconds(prog):
    try:
        with open(prog) as f: txt = f.read()
    except OSError:
        return 0.0
    if "progress=end" in txt: return dur
    for line in reversed(txt.splitlines()):
        if line.startswith("out_time_us="):
            try: return max(0, int(line.split("=")[1])) / 1e6
            except ValueError: return 0.0
    return 0.0

JOBS = LADDER + ([LFEJOB] if lfe else [])
queue = list(JOBS); running = {}; finished = set()
jobs = max(1, os.cpu_count() or 1)
while queue or running:
    while queue and len(running) < jobs:
        br = queue.pop(0); running[br] = start(br)
    for br, (p, prog) in list(running.items()):
        rc = p.poll()
        if rc is not None:
            if rc != 0:
                sys.stderr.write("\n"); sys.exit("ffmpeg failed for %d bps" % br)
            finished.add(br); del running[br]
    if dur > 0:
        got = len(finished) * dur + sum(done_seconds(pr) for _, pr in running.values())
        progress(UP_END + (ENC_END - UP_END) * got / (dur * len(JOBS)), "encoding")
    else:
        progress(UP_END + (ENC_END - UP_END) * len(finished) / len(JOBS), "encoding")
    time.sleep(0.1)

raws = {br: open(os.path.join(workdir, "core_%d.dts" % br), "rb").read() for br in JOBS}

# --- DTS core side-info parser (enough to read the bit allocation) ---
BA12 = [
 [(0,1),(1,2),(2,3),(3,4),(4,5),(5,6),(11,9),(10,9),(9,9),(8,9),(7,8),(6,8)],
 [(1,2),(2,3),(4,5),(11,7),(10,7),(9,7),(8,7),(7,7),(6,7),(5,6),(3,5),(0,1)],
 [(0,2),(4,3),(7,4),(11,7),(10,7),(9,6),(8,5),(3,3),(2,3),(6,4),(5,4),(1,3)],
 [(2,2),(3,3),(4,4),(5,5),(6,6),(7,7),(8,8),(9,9),(11,10),(10,10),(1,2),(0,2)],
 [(1,2),(2,3),(3,4),(4,5),(9,8),(8,8),(6,7),(7,8),(11,9),(10,9),(5,7),(0,1)]]
def build(t):
    d = {}; code = 0
    for sym, ln in t:
        d[(ln, code >> (32 - ln))] = sym + 1; code += 1 << (32 - ln)
    return d
TABS = [build(t) for t in BA12]

class Bits:
    def __init__(s, b, p): s.b = b; s.p = p * 8
    def r(s, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | ((s.b[s.p >> 3] >> (7 - (s.p & 7))) & 1); s.p += 1
        return v
    def vlc(s, t):
        v = 0
        for ln in range(1, 17):
            v = (v << 1) | s.r(1)
            if (ln, v) in t: return t[(ln, v)]
        raise ValueError("bad bit-allocation code")

def frame_info(raw, i):
    """(size, max_abits, LFE-data bit offset or None) of the core frame at byte offset i"""
    if raw[i:i+4] != b"\x7f\xfe\x80\x01":
        raise ValueError("lost DTS sync at byte %d" % i)
    b = Bits(raw, i); b.r(46); fs = b.r(14) + 1; b.r(25); lff = b.r(2); b.r(1); b.r(16)
    b.r(4); ch = b.r(3) + 1
    subs = [b.r(5) + 2 for _ in range(ch)]; vq = [b.r(5) + 1 for _ in range(ch)]
    [b.r(3) for _ in range(ch)]; [b.r(2) for _ in range(ch)]; [b.r(3) for _ in range(ch)]
    bh = [b.r(3) for _ in range(ch)]
    sel = [[0] * 10 for _ in range(ch)]
    for k in range(10):
        for c in range(ch): sel[c][k] = b.r(1 if k == 0 else 2 if k < 5 else 3)
    for k in range(10):
        for c in range(ch):
            if sel[c][k] < (1 if k == 0 else 3 if k < 5 else 7): b.r(2)
    b.r(5)
    pm = [[b.r(1) for _ in range(subs[c])] for c in range(ch)]
    for c in range(ch):
        for s in range(subs[c]):
            if pm[c][s]: b.r(12)
    m = 0; active = 0
    for c in range(ch):
        for _ in range(vq[c]):
            v = b.vlc(TABS[bh[c]]) if bh[c] < 5 else b.r(bh[c] - 1)
            m = max(m, v); active += v > 0
    # FFmpeg layout: 1-bit transition mode + 7-bit scale factor per active band, then LFE
    lfepos = (b.p - i * 8) + active * 8 if lff else None
    return fs, m, lfepos

# FFmpeg uses one fixed frame size per bitrate
fsize = {br: frame_info(raws[br], 0)[0] for br in JOBS}
total = len(raws[LADDER[0]]) // fsize[LADDER[0]]
for br in JOBS:
    if len(raws[br]) != total * fsize[br]:
        sys.exit("unexpected frame layout at %d bps" % br)

# --- 2) pick, per frame, the highest bitrate within the bit-allocation limit,
#        then pack into 14-bit words (sign-extended, 16-bit LE), 1024 words per frame ---
out = bytearray(int(round(leadin * 44100)) * 4)
fixed = 0; over = 0; used = set()
for n in range(total):
    pick = None
    for br in LADDER:
        _, m, lfepos = frame_info(raws[br], n * fsize[br])
        if m <= maxab: pick = br; break
    if pick is None: pick = LADDER[-1]; over += 1
    if pick != LADDER[0]: fixed += 1
    used.add(pick)
    off, fs = n * fsize[pick], fsize[pick]
    fr = bytearray(raws[pick][off:off+fs]) + bytes(FRAME - fs)
    if lfe:
        _, _, src_pos = frame_info(raws[LFEJOB], n * fsize[LFEJOB])
        a = raws[LFEJOB][n * fsize[LFEJOB]:(n + 1) * fsize[LFEJOB]]
        bits72 = (int.from_bytes(a, "big") >> (len(a) * 8 - src_pos - 72)) & ((1 << 72) - 1)
        v = int.from_bytes(fr, "big"); sh = FRAME * 8 - lfepos - 72
        v = (v & ~(((1 << 72) - 1) << sh)) | (bits72 << sh)
        fr = bytearray(v.to_bytes(FRAME, "big"))
    # FSIZE = 1791 (frame padded with zeros) and RATE = 22, like DTS-CD masters
    hdr = int.from_bytes(fr[4:10], "big")                # frame bits 32..79
    hdr = (hdr & ~(0x3FFF << 20)) | ((FRAME - 1) << 20)  # FSIZE: frame bits 46..59
    hdr = (hdr & ~(0x1F << 5)) | (22 << 5)               # RATE:  frame bits 70..74
    fr[4:10] = hdr.to_bytes(6, "big")
    v = int.from_bytes(fr, "big")
    words = [0] * 1024
    for k in range(1024):
        w = (v >> (14 * (1023 - k))) & 0x3FFF
        words[k] = w - 0x4000 if w & 0x2000 else w
    out += struct.pack("<1024h", *words)
    progress(ENC_END + (1 - ENC_END) * (n + 1) / total, "packing")

hdr = struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + len(out), b"WAVE",
                  b"fmt ", 16, 1, 2, 44100, 44100 * 4, 4, 16, b"data", len(out))
with open(dst, "wb") as f:
    f.write(hdr); f.write(out)

progress(1.0, "done", force=True)
if is_tty: sys.stderr.write("\r\033[K"); sys.stderr.flush()
print("   DTS: %d of %d frames re-encoded to stay at bit-allocation <= %d"
      % (fixed, total, maxab))
if over:
    print("   warning: %d frames still above the limit at the lowest bitrate" % over)
if bpm:
    print("   tempo: %.1f BPM" % bpm)
print("   time: %s" % fmt(time.time() - t0))
PYEOF


# ------------------------------------------------------------------ main
echo "flac2awesome $VERSION"
if [ "$OUTPUT" = truehd ]; then
  if [ "$THD_PATCHED" = 1 ]; then
    echo "output: Dolby TrueHD 5.1, 24-bit, native rate up to 192 kHz (patched encoder)"
  else
    echo "output: Dolby TrueHD 5.1, 24-bit, 48 kHz (stock encoder; run --setup-truehd for 96/192 kHz)"
  fi
elif [ "$OUTPUT" = flac ]; then
  echo "output: 6-channel FLAC, 24-bit, at each source's own sample rate"
else
  echo "output: DTS 5.1 WAV (44.1 kHz)"
fi
lfe_txt="LFE on (below $DTS_LFE_HZ Hz)"; [ "$DTS_LFE" = off ] && lfe_txt="LFE off"
if [ "$DTS_UPMIX" = stems ]; then
  if [ "$DTS_STEMS_MODE" = circle ]; then m="circle, one turn per $DTS_TURN_BARS bars"; else m="$DTS_STEMS_MODE"; fi
  echo "upmix: stems ($m), $lfe_txt"
elif [ "$DTS_UPMIX" = smart ]; then
  echo "upmix: smart (spread $DTS_SPREAD, surround ${DTS_SURROUND} dB, center $DTS_CENTER), $lfe_txt"
else
  echo "upmix: simple, $lfe_txt"
fi
# Foreign tags appended to a FLAC file (ID3v1, APEv2) are not part of the FLAC format: decoders
# hit them at the end of the stream and print "invalid sync code" errors. Detect them and convert
# from a temporary copy without them (same audio, same FLAC tags; the original is not touched).
appended_tags() {   # prints "<bytes to keep> <description>" or nothing
  python3 - "$1" <<'TAGPY'
import os, struct, sys
path = sys.argv[1]
size = end = os.path.getsize(path)
found = []
with open(path, "rb") as f:
    for _ in range(4):                      # tags can be stacked (e.g. APEv2 + ID3v1)
        if end >= 128:
            f.seek(end - 128)
            if f.read(3) == b"TAG":
                end -= 128; found.append("ID3v1"); continue
        if end >= 32:
            f.seek(end - 32)
            foot = f.read(32)
            if foot[:8] == b"APETAGEX":
                tsize, _, flags = struct.unpack("<III", foot[12:24])
                length = tsize + (32 if flags & 0x80000000 else 0)
                if 0 < length <= end:
                    end -= length; found.append("APEv2"); continue
        break
if found:
    print(end, " + ".join(reversed(found)))
TAGPY
}

# Integrity check: one silent decode computes the audio MD5 (compared with the checksum every
# FLAC stores) and lists the decoded frames (gaps = damaged frames, a short total = truncation).
# Prints one line: "OK", "UNVERIFIED <why>", "DAMAGED <details>" or "UNREADABLE <why>".
verify_flac() {
  python3 - "$1" "$tmp" <<'VERPY'
import os, struct, subprocess, sys
path, tmpd = sys.argv[1], sys.argv[2]

def mmss(t):
    t = int(t); return "%d:%02d" % (t // 60, t % 60)

# --- STREAMINFO (skipping a leading ID3v2 tag if present)
try:
    with open(path, "rb") as f:
        head = f.read(4096)
except OSError as e:
    print("UNREADABLE cannot read the file (%s)" % e.strerror); sys.exit()
off = 0
if head[:3] == b"ID3" and len(head) >= 10:
    sz = head[6:10]; off = 10 + ((sz[0] << 21) | (sz[1] << 14) | (sz[2] << 7) | sz[3])
    with open(path, "rb") as f:
        f.seek(off); head = f.read(4096); off = 0
if head[off:off + 4] != b"fLaC" or len(head) < off + 42:
    print("UNREADABLE not a FLAC file"); sys.exit()
si = head[off + 8:off + 42]
rate = (si[10] << 12) | (si[11] << 4) | (si[12] >> 4)
bits = (((si[12] & 1) << 4) | (si[13] >> 4)) + 1
total = ((si[13] & 0x0f) << 32) | struct.unpack(">I", si[14:18])[0]
md5_ref = si[18:34].hex()
if rate == 0:
    print("UNREADABLE invalid FLAC header"); sys.exit()

# --- decode once: MD5 of the samples + per-frame timestamps
pcm = {16: "pcm_s16le", 24: "pcm_s24le"}.get(bits)
md5file = os.path.join(tmpd, "verify.md5")
if os.path.exists(md5file): os.remove(md5file)
cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-i", path, "-map", "0:a:0"]
if pcm:
    cmd += ["-c:a", pcm, "-f", "md5", md5file]
cmd += ["-map", "0:a:0", "-c:a", pcm or "pcm_s32le", "-f", "framecrc", "-"]
r = subprocess.run(cmd, capture_output=True, text=True)
frames = []
for line in r.stdout.splitlines():
    if line.startswith("#") or not line.strip():
        continue
    parts = [x.strip() for x in line.split(",")]
    try:
        frames.append((int(parts[2]), int(parts[3])))      # pts, duration (1/rate units)
    except (IndexError, ValueError):
        pass
errors = [l for l in r.stderr.splitlines() if l.strip()]
if not frames:
    why = errors[-1].split("]")[-1].strip() if errors else "no audio could be decoded"
    print("UNREADABLE %s" % why); sys.exit()

gaps = []
for (p0, d0), (p1, _) in zip(frames, frames[1:]):
    if p1 > p0 + d0 + 1:
        gaps.append((p0 + d0) / rate)
decoded = frames[-1][0] + frames[-1][1] - frames[0][0]
problems = []
if gaps:
    where = ", ".join(mmss(g) for g in gaps[:3]) + (" ..." if len(gaps) > 3 else "")
    problems.append("%d damaged frame%s near %s" % (len(gaps), "" if len(gaps) == 1 else "s", where))
if total and decoded < total - rate // 100:
    problems.append("file ends %.1f s early, cut off at %s" % ((total - decoded) / rate, mmss(decoded / rate)))
md5_ok = None
if pcm and md5_ref != "0" * 32 and os.path.exists(md5file):
    got = open(md5file).read().strip().split("=")[-1]
    md5_ok = (got == md5_ref)
    if not md5_ok and not problems:
        problems.append("audio does not match the file's checksum")
if problems or (errors and not md5_ok):
    if not problems:
        problems.append("%d decoder error%s" % (len(errors), "" if len(errors) == 1 else "s"))
    print("DAMAGED " + "; ".join(problems))
elif md5_ok:
    print("OK")
elif md5_ref == "0" * 32:
    print("UNVERIFIED the file stores no checksum")
else:
    print("UNVERIFIED %d-bit audio cannot be checked against its checksum" % bits)
VERPY
}

converted=0; damaged=(); skipped=(); failed=()
for f in "${files[@]}"; do
  base="$(basename "$f")"; name="${base%.*}"
  echo "== $base"
  src="$f"
  if tags="$(appended_tags "$f")" && [ -n "$tags" ]; then
    keep="${tags%% *}"
    echo "   note: $base has ${tags#* } tag data appended (not part of the FLAC format);"
    echo "         ignored for the conversion, audio and FLAC tags are unaffected"
    head -c "$keep" "$f" > "$tmp/source.flac"
    src="$tmp/source.flac"
  fi
  status="$(verify_flac "$src" 2>/dev/null || echo "UNREADABLE verification failed")"
  case "$status" in
    UNREADABLE*)
      echo "   skipped: ${status#UNREADABLE }"
      skipped+=("$base: ${status#UNREADABLE }")
      rm -f "$tmp/source.flac"; continue ;;
    DAMAGED*)
      echo "   warning: the source is damaged (${status#DAMAGED });"
      echo "            converting anyway, like a player would: the damaged spots are in the output too"
      damaged+=("$base: ${status#DAMAGED }")
      # decode once into a repaired copy (bad frames skipped), so the conversion runs cleanly
      bits_fmt="s32"; bps=24
      case "$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_raw_sample -of default=nw=1:nk=1 "$src" 2>/dev/null)" in
        16) bits_fmt="s16"; bps=16 ;;
      esac
      if ffmpeg -nostdin -hide_banner -loglevel quiet -y -i "$src" -map 0:a:0 -map "0:v?" -map_metadata 0 \
           -c:a flac -sample_fmt "$bits_fmt" -bits_per_raw_sample "$bps" -compression_level 0 \
           -c:v copy "$tmp/repaired.flac" && [ -s "$tmp/repaired.flac" ]; then
        src="$tmp/repaired.flac"
      fi ;;
    UNVERIFIED*)
      echo "   note: ${status#UNVERIFIED }; integrity not verified" ;;
  esac
  case "$OUTPUT" in
    truehd) out="$OUTDIR/${name}_TrueHD-5.1.mp4" ;;
    flac)   out="$OUTDIR/${name}_FLAC-5.1.flac" ;;
    *)      out="$OUTDIR/${name}_DTS-5.1.wav" ;;
  esac
  if "$PY" "$tmp/dtswav.py" "$src" "$out" "$tmp"; then
    echo "   -> $out"
    converted=$((converted + 1))
  else
    echo "   failed: the conversion stopped with an error (see above); continuing with the next file"
    failed+=("$base")
    rm -f "$out"
  fi
  rm -f "$tmp/source.flac" "$tmp/repaired.flac"
done

# ------------------------------------------------------------------ summary
total_files=${#files[@]}
if [ ${#damaged[@]} -eq 0 ] && [ ${#skipped[@]} -eq 0 ] && [ ${#failed[@]} -eq 0 ]; then
  echo "Done: $converted of $total_files converted."
else
  echo "Done: $converted of $total_files converted."
  for d in "${damaged[@]}"; do echo "  damaged source (converted anyway): $d"; done
  for d in "${skipped[@]}"; do echo "  skipped: $d"; done
  for d in "${failed[@]}"; do echo "  failed: $d"; done
fi
[ ${#failed[@]} -eq 0 ] && [ ${#skipped[@]} -eq 0 ]
