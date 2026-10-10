#!/usr/bin/env python3
"""Prepare the shared NI testbench with direct NMU-to-NSU connections."""
import argparse
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "sim"))
from prepare import prepare

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--profile")
    args = parser.parse_args()
    prepare(args.out, args.profile, direct=True)
