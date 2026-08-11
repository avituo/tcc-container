#!/usr/bin/env python3
"""Derive frozen HTTP and resource statistics without deleting raw samples."""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path
from typing import Iterable


def nearest_rank(values: list[float], percentile: float) -> float:
    if not values:
        raise ValueError("cannot calculate a percentile for an empty sample")
    ordered = sorted(values)
    rank = max(1, math.ceil((percentile / 100) * len(ordered)))
    return ordered[rank - 1]


def http_summary(jtl_path: Path, duration_seconds: int) -> dict[str, object]:
    elapsed: list[float] = []
    errors = 0
    error_messages: defaultdict[str, int] = defaultdict(int)

    with jtl_path.open(encoding="utf-8", newline="") as jtl_file:
        for row in csv.DictReader(jtl_file):
            elapsed.append(float(row["elapsed"]))
            if row["success"].lower() != "true":
                errors += 1
                message = row.get("failureMessage") or row.get("responseMessage") or "unspecified"
                error_messages[message] += 1

    if not elapsed:
        raise ValueError(f"no HTTP samples found in {jtl_path}")

    sample_count = len(elapsed)
    return {
        "sample_count": sample_count,
        "average_ms": statistics.fmean(elapsed),
        "median_ms": statistics.median(elapsed),
        "p90_ms": nearest_rank(elapsed, 90),
        "p95_ms": nearest_rank(elapsed, 95),
        "p99_ms": nearest_rank(elapsed, 99),
        "minimum_ms": min(elapsed),
        "maximum_ms": max(elapsed),
        "standard_deviation_ms": statistics.pstdev(elapsed),
        "throughput_requests_per_second": sample_count / duration_seconds,
        "error_count": errors,
        "error_percentage": (errors / sample_count) * 100,
        "error_messages": dict(sorted(error_messages.items())),
        "percentile_method": "nearest-rank",
        "standard_deviation_method": "population",
        "throughput_denominator_seconds": duration_seconds,
    }


def summarize_numeric(rows: Iterable[dict[str, str]], cpu_field: str, memory_field: str) -> dict[str, float]:
    materialized = list(rows)
    cpu = [float(row[cpu_field]) for row in materialized]
    memory = [float(row[memory_field]) for row in materialized]
    if not cpu:
        raise ValueError("resource sample is empty")

    return {
        "sample_count": len(cpu),
        "average_cpu_percent": statistics.fmean(cpu),
        "maximum_cpu_percent": max(cpu),
        "average_memory_bytes": statistics.fmean(memory),
        "maximum_memory_bytes": max(memory),
    }


def resource_summary(individual_path: Path, totals_path: Path) -> dict[str, object]:
    services: defaultdict[str, list[dict[str, str]]] = defaultdict(list)
    with individual_path.open(encoding="utf-8", newline="") as individual_file:
        for row in csv.DictReader(individual_file):
            services[row["service"]].append(row)

    with totals_path.open(encoding="utf-8", newline="") as totals_file:
        totals = list(csv.DictReader(totals_file))

    reused_refreshes = sum(row.get("docker_refresh_reused", "false").lower() == "true" for row in totals)

    return {
        "individual_containers": {
            service: summarize_numeric(rows, "cpu_percent", "memory_used_bytes")
            for service, rows in sorted(services.items())
        },
        "architecture_total": summarize_numeric(
            totals,
            "cpu_percent_total",
            "memory_used_bytes_total",
        ),
        "sampling_quality": {
            "scheduled_interval_seconds": 1,
            "reused_docker_refresh_count": reused_refreshes,
            "distinct_docker_refresh_count": len(totals) - reused_refreshes,
        },
        "cpu_total_method": "sum of Docker container CPU percentages per one-second sample",
        "memory_total_method": "sum of Docker container memory-used bytes per one-second sample",
    }


def write_json(path: Path, payload: dict[str, object]) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timed-jtl", type=Path, required=True)
    parser.add_argument("--warmup-jtl", type=Path, required=True)
    parser.add_argument("--individual-resources", type=Path, required=True)
    parser.add_argument("--total-resources", type=Path, required=True)
    parser.add_argument("--measurement-seconds", type=int, required=True)
    parser.add_argument("--warmup-seconds", type=int, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    args = parser.parse_args()

    timed = http_summary(args.timed_jtl, args.measurement_seconds)
    warmup = http_summary(args.warmup_jtl, args.warmup_seconds)
    resources = resource_summary(args.individual_resources, args.total_resources)

    write_json(args.output_directory / "http-summary.json", timed)
    write_json(args.output_directory / "warmup-summary.json", warmup)
    write_json(args.output_directory / "resource-summary.json", resources)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
