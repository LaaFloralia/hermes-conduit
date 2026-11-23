#!/usr/bin/env python3
"""Compatibility entry point for the fixture-only lab performance runner."""
import argparse
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--skip-build", action="store_true", help="Reuse a matching lab build")
    args = parser.parse_args()
    runner = Path(__file__).resolve().parents[1] / "lab/perf.py"
    return subprocess.run([sys.executable, str(runner), "run", "--out", str(args.output), "--runs", str(args.runs)]
                          + (["--reuse-build"] if args.skip_build else [])).returncode


if __name__ == "__main__":
    sys.exit(main())
