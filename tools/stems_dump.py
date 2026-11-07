#!/usr/bin/env python3
"""stems_dump.py - split audio files into stems with Demucs (htdemucs_6s).

Usage:  python stems_dump.py file.flac [more files...]
Writes  stems/<name>_<stem>.flac  (24-bit, 44.1 kHz stereo) for the stems
        drums, bass, other, vocals, guitar, piano.

Audio is read and written with ffmpeg (no torchaudio file I/O), so it works with
current PyTorch / torchaudio versions. Uses the GPU when available.
"""
import os, sys, subprocess, time
import numpy as np
import torch
from demucs.pretrained import get_model
from demucs.apply import apply_model

MODEL = os.environ.get("DEMUCS_MODEL", "htdemucs_6s")
SR = 44100

def read(path):
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path,
                          "-map", "0:a:0", "-ac", "2", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype="<f4").reshape(-1, 2).T.copy()   # (2, n)

def write(path, x):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-f", "f32le", "-ar", str(SR), "-ac", "2", "-i", "-",
                    "-c:a", "flac", "-sample_fmt", "s32", "-bits_per_raw_sample", "24", path],
                   input=np.ascontiguousarray(x.T, dtype="<f4").tobytes(), check=True)

def main():
    files = sys.argv[1:]
    if not files:
        sys.exit(__doc__)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    print("device:", device, torch.cuda.get_device_name(0) if device == "cuda" else "")
    model = get_model(MODEL)
    model.eval()
    os.makedirs("stems", exist_ok=True)
    for f in files:
        t0 = time.time()
        name = os.path.splitext(os.path.basename(f))[0]
        wav = torch.from_numpy(read(f))
        ref = wav.mean(0)
        mean, std = ref.mean(), ref.std() + 1e-8
        with torch.no_grad():
            out = apply_model(model, ((wav - mean) / std)[None], device=device,
                              shifts=1, split=True, overlap=0.25, progress=True)[0]
        out = out * std + mean
        for src, x in zip(model.sources, out):
            write(os.path.join("stems", "%s_%s.flac" % (name, src)), x.cpu().numpy())
        print("%s: %s  (%.1f s)" % (name, ", ".join(model.sources), time.time() - t0))

if __name__ == "__main__":
    main()
