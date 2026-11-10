#!/usr/bin/env python3
"""Summarize only completed UI samples; never turn missing data into zero."""
import argparse
import json
import statistics
from pathlib import Path


def summarize(log):
    samples = {}
    unavailable = set()
    for line in log.splitlines():
        if "LAA_PERF_UNAVAILABLE " in line:
            unavailable.add(line.split("LAA_PERF_UNAVAILABLE ", 1)[1].strip())
        if "LAA_PERF {" not in line:
            continue
        row = json.loads(line.split("LAA_PERF ", 1)[1])
        if row["ready"]:
            samples.setdefault(row["metric"], []).append(row["ms"])
    return {"metrics": {name: {"count": len(values), "median_ms": round(statistics.median(values), 2),
                               "samples_ms": values} for name, values in sorted(samples.items())},
            "unavailable": sorted(unavailable)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    result = summarize(args.log.read_text())
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    for name, data in result["metrics"].items():
        print(f"{name}: {data['median_ms']:.2f} ms (n={data['count']})")
