#!/usr/bin/env python3
"""Create a machine-readable release manifest for a frozen preprocessing run."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_command(command: list[str]) -> dict[str, Any]:
    try:
        completed = subprocess.run(command, check=False, text=True, capture_output=True)
    except FileNotFoundError:
        return {"command": command, "available": False}
    return {
        "command": command,
        "available": True,
        "returncode": completed.returncode,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
    }


def checksum_selected(paths: list[Path]) -> dict[str, str]:
    checksums = {}
    for path in paths:
        if path.exists() and path.is_file():
            checksums[str(path)] = sha256_file(path)
    return checksums


def read_text_if_exists(path: Path | None) -> str | None:
    if path is None or not path.exists():
        return None
    return path.read_text(encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--command-log", type=Path)
    parser.add_argument("--bids-validator-log", type=Path)
    parser.add_argument("--sdc-audit", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--extra-file", type=Path, action="append", default=[])
    args = parser.parse_args()

    paths_to_checksum = [args.config, *args.extra_file]
    for optional_path in (args.command_log, args.bids_validator_log, args.sdc_audit):
        if optional_path is not None:
            paths_to_checksum.append(optional_path)

    manifest = {
        "created_at_utc": datetime.now(timezone.utc).isoformat(),
        "host": {
            "platform": platform.platform(),
            "python": platform.python_version(),
            "cwd": os.getcwd(),
        },
        "environment": {
            key: os.environ.get(key)
            for key in (
                "FMRIPREP_IMAGE",
                "CONTAINER_RUNTIME",
                "TEMPLATEFLOW_HOME",
                "SUBJECT_ANATOMICAL_REFERENCE",
                "RANDOM_SEED",
                "SLICE_TIME_REF",
            )
        },
        "version_checks": {
            "docker": run_command(["docker", "--version"]),
            "apptainer": run_command(["apptainer", "--version"]),
            "singularity": run_command(["singularity", "--version"]),
            "bids_validator": run_command(["bids-validator", "--version"]),
        },
        "records": {
            "config": read_text_if_exists(args.config),
            "command_log": read_text_if_exists(args.command_log),
            "bids_validator_log": read_text_if_exists(args.bids_validator_log),
            "sdc_audit_csv": read_text_if_exists(args.sdc_audit),
        },
        "checksums": checksum_selected(paths_to_checksum),
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2, sort_keys=True), encoding="utf-8")
    print(f"Wrote release manifest: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
