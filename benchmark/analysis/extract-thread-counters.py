#!/usr/bin/env python3
"""Persist per-thread POST counters between warm-up and timed JMeter runs."""

from __future__ import annotations

import argparse
import csv
import re
from collections import Counter
from pathlib import Path


THREAD_NUMBER = re.compile(r"-(\d+)$")


def extract(input_path: Path) -> dict[int, int]:
    counts: Counter[int] = Counter()
    with input_path.open(encoding="utf-8", newline="") as input_file:
        for row in csv.DictReader(input_file):
            match = THREAD_NUMBER.search(row["threadName"])
            if match is None:
                raise ValueError(f"cannot extract thread number from {row['threadName']!r}")
            counts[int(match.group(1))] += 1

    return dict(sorted(counts.items()))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--threads", type=int, required=True)
    args = parser.parse_args()

    counts = extract(args.input)
    expected_threads = set(range(1, args.threads + 1))
    if set(counts) != expected_threads:
        raise SystemExit(
            f"warm-up thread mismatch: expected {sorted(expected_threads)}, found {sorted(counts)}"
        )

    with args.output.open("w", encoding="utf-8") as output_file:
        output_file.write("# Generated from warm-up.jtl; contains no credentials.\n")
        for thread_number, count in counts.items():
            output_file.write(f"tcc.counter.{thread_number}={count}\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
