#!/usr/bin/env python3
"""Link BOLD sidecars to BIDS B0 fieldmaps for one converted subject/session.

The converter can derive scanner metadata but cannot know the study-specific
association between a session's AP/PA EPI pair and its BOLD runs.  This helper
encodes the IFOCUS convention: the sole ``acq-opphase`` AP/PA pair applies to
every BOLD run in the same subject/session.
"""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: JSON root must be an object")
    return data


def write_json(path: Path, data: dict[str, Any]) -> None:
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
        Path(temporary_name).replace(path)
    except BaseException:
        Path(temporary_name).unlink(missing_ok=True)
        raise


def entities_from_name(path: Path) -> dict[str, str]:
    entities: dict[str, str] = {}
    for part in path.stem.split("_"):
        if "-" in part:
            key, value = part.split("-", 1)
            entities[key] = value
    return entities


def set_required_value(path: Path, field: str, value: str) -> bool:
    data = load_json(path)
    current = data.get(field)
    if current is None:
        data[field] = value
        write_json(path, data)
        return True
    if current == value or current == [value]:
        return False
    raise ValueError(f"{path}: {field} already has conflicting value {current!r}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bids_dir", type=Path)
    parser.add_argument("--participant-label", required=True)
    parser.add_argument("--session-label", required=True)
    args = parser.parse_args()

    subject = args.participant_label.removeprefix("sub-")
    session = args.session_label.removeprefix("ses-")
    session_dir = args.bids_dir / f"sub-{subject}" / f"ses-{session}"
    fmap_dir = session_dir / "fmap"
    func_dir = session_dir / "func"
    if not fmap_dir.is_dir() or not func_dir.is_dir():
        parser.error(f"expected fmap and func directories under {session_dir}")

    fieldmaps: dict[str, list[Path]] = {"AP": [], "PA": []}
    for path in sorted(fmap_dir.glob("*_epi.json")):
        entities = entities_from_name(path)
        if entities.get("acq") == "opphase" and entities.get("dir") in fieldmaps:
            fieldmaps[entities["dir"]].append(path)
    invalid = {direction: paths for direction, paths in fieldmaps.items() if len(paths) != 1}
    if invalid:
        details = ", ".join(f"{direction}={len(paths)}" for direction, paths in invalid.items())
        parser.error(f"expected exactly one acq-opphase EPI JSON per direction ({details})")

    bolds = sorted(func_dir.glob("*_bold.json"))
    if not bolds:
        parser.error(f"no BOLD JSON sidecars found in {func_dir}")

    identifier = f"sub-{subject}_ses-{session}_acq-opphase"
    changed = 0
    for path in fieldmaps["AP"] + fieldmaps["PA"]:
        changed += set_required_value(path, "B0FieldIdentifier", identifier)
    for path in bolds:
        changed += set_required_value(path, "B0FieldSource", identifier)

    print(
        f"SDC metadata: sub-{subject} ses-{session}; "
        f"2 fieldmaps, {len(bolds)} BOLD sidecars, {changed} updates"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
