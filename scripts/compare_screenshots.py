#!/usr/bin/env python3
"""Compare two PNG screenshots with a tolerance, for Tier 2 real-skin regression checks.

Usage:
    python3 scripts/compare_screenshots.py golden.png candidate.png [--tolerance 3.0] [--diff-out diff.png]

Exit status is non-zero if the mean absolute per-pixel difference exceeds --tolerance.
Use this against frame.png produced by the SKINNER_DEBUG_STDIN `dump`/`screenshot`
commands (see PLAN.md "Debugging & Testing Tools").
"""

import argparse
import sys

from PIL import Image, ImageChops


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("golden", help="Path to the known-good reference PNG")
    parser.add_argument("candidate", help="Path to the newly captured PNG")
    parser.add_argument("--tolerance", type=float, default=3.0,
                         help="Max allowed mean absolute per-channel difference (0-255, default 3.0)")
    parser.add_argument("--diff-out", help="Optional path to write a visual diff PNG")
    args = parser.parse_args()

    golden = Image.open(args.golden).convert("RGBA")
    candidate = Image.open(args.candidate).convert("RGBA")

    if golden.size != candidate.size:
        print(f"SIZE MISMATCH: golden={golden.size} candidate={candidate.size}")
        return 1

    diff = ImageChops.difference(golden, candidate)
    histogram = diff.histogram()

    channels = 4
    mean_diff = 0.0
    for c in range(channels):
        channel_hist = histogram[c * 256:(c + 1) * 256]
        channel_sum = sum(value * count for value, count in enumerate(channel_hist))
        channel_pixels = sum(channel_hist)
        mean_diff += channel_sum / channel_pixels
    mean_diff /= channels

    if args.diff_out:
        diff.save(args.diff_out)

    print(f"mean absolute diff: {mean_diff:.4f} (tolerance {args.tolerance})")
    if mean_diff > args.tolerance:
        print("FAIL: difference exceeds tolerance")
        return 1

    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
