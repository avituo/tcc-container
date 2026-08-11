#!/usr/bin/env python3
"""Collect one Docker stats sample per second and calculate architecture totals."""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path


ARCHITECTURES = {
    "monolith": {
        "project": "tcc-monolith-experiment",
        "services": ("monolith", "mysql"),
    },
    "microservices": {
        "project": "tcc-microservices-experiment",
        "services": ("gateway", "auth", "product", "order", "mysql"),
    },
}

BYTE_UNITS = {
    "B": 1,
    "kB": 1000,
    "MB": 1000**2,
    "GB": 1000**3,
    "TB": 1000**4,
    "KiB": 1024,
    "MiB": 1024**2,
    "GiB": 1024**3,
    "TiB": 1024**4,
}

ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def parse_bytes(value: str) -> int:
    match = re.fullmatch(r"\s*([0-9.]+)\s*([KMGT]?i?B)\s*", value)
    if match is None:
        raise ValueError(f"unsupported Docker memory value: {value!r}")

    return round(float(match.group(1)) * BYTE_UNITS[match.group(2)])


def discover_containers(architecture: str) -> dict[str, dict[str, str]]:
    definition = ARCHITECTURES[architecture]
    completed = subprocess.run(
        [
            "docker",
            "ps",
            "--filter",
            f"label=com.docker.compose.project={definition['project']}",
            "--format",
            "{{.ID}}",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    container_ids = [line.strip() for line in completed.stdout.splitlines() if line.strip()]
    if not container_ids:
        raise RuntimeError(f"no running containers found for {architecture}")

    inspected = subprocess.run(
        [
            "docker",
            "inspect",
            "--format",
            '{{.Id}}|{{.Name}}|{{index .Config.Labels "com.docker.compose.service"}}',
            *container_ids,
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    containers: dict[str, dict[str, str]] = {}
    for line in inspected.stdout.splitlines():
        container_id, container_name, service = line.split("|", maxsplit=2)
        containers[container_name.removeprefix("/")] = {
            "id": container_id,
            "service": service,
        }

    actual_services = {container["service"] for container in containers.values()}
    expected_services = set(definition["services"])
    if actual_services != expected_services:
        raise RuntimeError(
            f"resource boundary mismatch for {architecture}: "
            f"expected {sorted(expected_services)}, found {sorted(actual_services)}"
        )

    return containers


def collect(
    architecture: str,
    sample_count: int,
    output_directory: Path,
    ready_file: Path | None = None,
    start_file: Path | None = None,
) -> None:
    containers = discover_containers(architecture)
    output_directory.mkdir(parents=True, exist_ok=False)

    raw_path = output_directory / "docker-stats.raw.jsonl"
    individual_path = output_directory / "docker-stats-individual.csv"
    totals_path = output_directory / "docker-stats-totals.csv"

    command = [
        "docker",
        "stats",
        "--format",
        "{{json .}}",
    ]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if process.stdout is None or process.stderr is None:
        raise RuntimeError("unable to capture docker stats output")

    individual_fields = (
        "sample_index",
        "captured_at_utc",
        "docker_refresh_sequence",
        "docker_refresh_captured_at_utc",
        "docker_refresh_reused",
        "architecture",
        "service",
        "container_id",
        "container_name",
        "cpu_percent",
        "memory_used_bytes",
        "memory_limit_bytes",
        "memory_percent",
        "pids",
        "network_io",
        "block_io",
    )
    total_fields = (
        "sample_index",
        "captured_at_utc",
        "docker_refresh_sequence",
        "docker_refresh_captured_at_utc",
        "docker_refresh_reused",
        "architecture",
        "cpu_percent_total",
        "memory_used_bytes_total",
        "memory_limit_bytes_total",
    )

    state_condition = threading.Condition()
    state: dict[str, object] = {
        "snapshot": None,
        "sequence": 0,
        "captured_at_utc": None,
        "invalid_refresh_count": 0,
        "error": None,
    }

    def read_docker_stats() -> None:
        current_refresh: dict[str, dict[str, object]] = {}
        try:
            for line in process.stdout:
                if ANSI_ESCAPE.search(line):
                    current_refresh = {}

                normalized_line = ANSI_ESCAPE.sub("", line).strip()
                if not normalized_line:
                    continue

                try:
                    payload = json.loads(normalized_line)
                except json.JSONDecodeError as failure:
                    raise RuntimeError(f"invalid Docker stats JSON line: {line!r}") from failure

                container_name = str(payload.get("Name", ""))
                if container_name not in containers:
                    continue

                required_numeric_fields = ("CPUPerc", "MemPerc", "PIDs")
                if any(str(payload.get(field, "--")).strip() == "--" for field in required_numeric_fields):
                    with state_condition:
                        state["invalid_refresh_count"] = int(state["invalid_refresh_count"]) + 1
                    current_refresh = {}
                    continue

                memory_used, memory_limit = str(payload["MemUsage"]).split("/", maxsplit=1)
                current_refresh[container_name] = {
                    "service": containers[container_name]["service"],
                    "container_id": containers[container_name]["id"],
                    "container_name": container_name,
                    "cpu_percent": float(str(payload["CPUPerc"]).rstrip("%")),
                    "memory_used_bytes": parse_bytes(memory_used),
                    "memory_limit_bytes": parse_bytes(memory_limit),
                    "memory_percent": float(str(payload["MemPerc"]).rstrip("%")),
                    "pids": int(payload["PIDs"]),
                    "network_io": payload["NetIO"],
                    "block_io": payload["BlockIO"],
                }

                if len(current_refresh) != len(containers):
                    continue

                refresh_captured_at = datetime.now(timezone.utc).isoformat()
                with state_condition:
                    state["snapshot"] = dict(current_refresh)
                    state["sequence"] = int(state["sequence"]) + 1
                    state["captured_at_utc"] = refresh_captured_at
                    state_condition.notify_all()

                if ready_file is not None and not ready_file.exists():
                    ready_file.write_text("ready\n", encoding="utf-8")
                current_refresh = {}
        except (OSError, RuntimeError, ValueError) as failure:
            with state_condition:
                state["error"] = failure
                state_condition.notify_all()

    reader = threading.Thread(target=read_docker_stats, name="docker-stats-reader", daemon=True)
    reader.start()

    sample_index = 0
    try:
        with (
            raw_path.open("w", encoding="utf-8") as raw_file,
            individual_path.open("w", encoding="utf-8", newline="") as individual_file,
            totals_path.open("w", encoding="utf-8", newline="") as totals_file,
        ):
            individual_writer = csv.DictWriter(individual_file, fieldnames=individual_fields)
            total_writer = csv.DictWriter(totals_file, fieldnames=total_fields)
            individual_writer.writeheader()
            total_writer.writeheader()

            with state_condition:
                while state["snapshot"] is None and state["error"] is None:
                    state_condition.wait(timeout=0.5)
                if state["error"] is not None:
                    raise RuntimeError(str(state["error"]))

            while start_file is not None and not start_file.exists():
                with state_condition:
                    if state["error"] is not None:
                        raise RuntimeError(str(state["error"]))
                time.sleep(0.01)

            sampling_started_at = time.monotonic()
            last_refresh_sequence: int | None = None

            for sample_index in range(1, sample_count + 1):
                scheduled_at = sampling_started_at + sample_index
                remaining = scheduled_at - time.monotonic()
                if remaining > 0:
                    time.sleep(remaining)

                with state_condition:
                    if state["error"] is not None:
                        raise RuntimeError(str(state["error"]))
                    current_sample = state["snapshot"]
                    refresh_sequence = int(state["sequence"])
                    refresh_captured_at = str(state["captured_at_utc"])
                    invalid_refresh_count = int(state["invalid_refresh_count"])

                if not isinstance(current_sample, dict):
                    raise RuntimeError("Docker stats snapshot disappeared during sampling")

                refresh_reused = refresh_sequence == last_refresh_sequence
                last_refresh_sequence = refresh_sequence
                captured_at = datetime.now(timezone.utc).isoformat()
                raw_entry = {
                    "sample_index": sample_index,
                    "captured_at_utc": captured_at,
                    "docker_refresh_sequence": refresh_sequence,
                    "docker_refresh_captured_at_utc": refresh_captured_at,
                    "docker_refresh_reused": refresh_reused,
                    "invalid_refresh_count_cumulative": invalid_refresh_count,
                    "architecture": architecture,
                    "docker_payloads": current_sample,
                }
                raw_file.write(json.dumps(raw_entry, sort_keys=True) + "\n")

                for normalized_sample in sorted(current_sample.values(), key=lambda item: str(item["service"])):
                    individual_writer.writerow(
                        {
                            "sample_index": sample_index,
                            "captured_at_utc": captured_at,
                            "docker_refresh_sequence": refresh_sequence,
                            "docker_refresh_captured_at_utc": refresh_captured_at,
                            "docker_refresh_reused": str(refresh_reused).lower(),
                            "architecture": architecture,
                            **normalized_sample,
                        }
                    )

                total_writer.writerow(
                    {
                        "sample_index": sample_index,
                        "captured_at_utc": captured_at,
                        "docker_refresh_sequence": refresh_sequence,
                        "docker_refresh_captured_at_utc": refresh_captured_at,
                        "docker_refresh_reused": str(refresh_reused).lower(),
                        "architecture": architecture,
                        "cpu_percent_total": sum(float(item["cpu_percent"]) for item in current_sample.values()),
                        "memory_used_bytes_total": sum(int(item["memory_used_bytes"]) for item in current_sample.values()),
                        "memory_limit_bytes_total": sum(int(item["memory_limit_bytes"]) for item in current_sample.values()),
                    }
                )

                raw_file.flush()
                individual_file.flush()
                totals_file.flush()
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        reader.join(timeout=5)

    if sample_index != sample_count:
        error_output = process.stderr.read().strip()
        raise RuntimeError(
            f"expected {sample_count} Docker stats samples, collected {sample_index}; {error_output}"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--architecture", choices=ARCHITECTURES, required=True)
    parser.add_argument("--samples", type=int, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument("--start-file", type=Path)
    args = parser.parse_args()

    if args.samples < 1:
        parser.error("--samples must be positive")
    if (args.ready_file is None) != (args.start_file is None):
        parser.error("--ready-file and --start-file must be supplied together")

    try:
        collect(
            args.architecture,
            args.samples,
            args.output_directory,
            args.ready_file,
            args.start_file,
        )
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as failure:
        print(f"resource collection failed: {failure}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
