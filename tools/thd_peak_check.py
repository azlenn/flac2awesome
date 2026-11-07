#!/usr/bin/env python3
"""thd_peak_check.py - check a raw TrueHD stream against its declared peak bitrate.

Usage:  ffmpeg -i input.mp4 -c copy -f truehd stream.thd
        python3 thd_peak_check.py stream.thd [label]

Reads every access unit, takes the peak bitrate from the first major sync header and
reports how many access units exceed it (each access unit lasts 1/1200 s).
"""
import sys, struct
import numpy as np

def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    d = open(sys.argv[1], "rb").read()
    label = sys.argv[2] if len(sys.argv) > 2 else sys.argv[1]
    i = 0; sizes = []; peakfield = None; rate = None; majors = 0
    while i + 4 <= len(d):
        ln = (struct.unpack(">H", d[i:i + 2])[0] & 0xfff) * 2     # access unit length
        if ln == 0:
            sys.exit("corrupt stream at byte %d" % i)
        if d[i + 4:i + 8] == b"\xf8\x72\x6f\xba":                 # TrueHD major sync
            majors += 1
            if peakfield is None:
                rb = d[i + 8] >> 4
                rate = (48000 if rb < 8 else 44100) << (rb & 7)
                peakfield = struct.unpack(">H", d[i + 18:i + 20])[0] & 0x7fff
        sizes.append(ln); i += ln
    if peakfield is None:
        sys.exit("no TrueHD major sync found")
    br = np.array(sizes) * 8 * 1200.0                              # bits/s per access unit
    peak = (peakfield * rate + 8) >> 4
    over = int((br > peak).sum())
    print("%s: %d Hz, %d access units, avg %.2f Mbps, max %.2f Mbps, declared peak %.2f Mbps,"
          " %d access units above it (%.2f%%)"
          % (label, rate, len(br), br.mean() / 1e6, br.max() / 1e6, peak / 1e6, over,
             100.0 * over / len(br)))
    sys.exit(1 if over else 0)

if __name__ == "__main__":
    main()
