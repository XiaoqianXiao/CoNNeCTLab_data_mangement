#!/usr/bin/env python3
"""Audit BIDS AP/PA fieldmap metadata before fMRIPrep production.

The audit checks the project-standard B0FieldIdentifier/B0FieldSource mapping,
phase-encoding/readout metadata, optional IntendedFor compatibility, and basic
fieldmap geometry when nibabel is installed.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


PE_OPPOSITES = {
    "i": "i-",
    "i-": "i",
    "j": "j-",
    "j-": "j",
    "k": "k-",
    "k-": "k",
}


@dataclass(frozen=True)
class Issue:
    severity: str
    path: Path
    field: str
    message: str


@dataclass(frozen=True)
class JsonSidecar:
    path: Path
    data: dict[str, Any]
    subject: str
    session: str


def load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            loaded = json.load(handle)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(loaded, dict):
        raise ValueError(f"{path}: JSON root must be an object")
    return loaded


def as_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [item for item in value if isinstance(item, str)]
    return []


def entity_from_parts(parts: tuple[str, ...], prefix: str, default: str) -> str:
    for part in parts:
        if part.startswith(prefix):
            return part
    return default


def json_to_image_path(json_path: Path) -> Path | None:
    stem = json_path.with_suffix("")
    for suffix in (".nii.gz", ".nii"):
        candidate = Path(f"{stem}{suffix}")
        if candidate.exists():
            return candidate
    return None


def read_image_geometry(image_path: Path) -> tuple[tuple[int, ...], tuple[float, ...], tuple[float, ...]] | None:
    try:
        import nibabel as nib  # type: ignore[import-not-found]
    except ImportError:
        return None

    image = nib.load(str(image_path))
    shape = tuple(int(value) for value in image.shape[:3])
    zooms = tuple(float(value) for value in image.header.get_zooms()[:3])
    affine_key = tuple(round(float(value), 4) for value in image.affine.ravel())
    return shape, zooms, affine_key


def collect_sidecars(bids_dir: Path) -> tuple[list[JsonSidecar], list[JsonSidecar]]:
    fmap_jsons = []
    bold_jsons = []
    for path in sorted(bids_dir.rglob("*.json")):
        rel_parts = path.relative_to(bids_dir).parts
        try:
            sidecar = JsonSidecar(
                path=path,
                data=load_json(path),
                subject=entity_from_parts(rel_parts, "sub-", "unknown-subject"),
                session=entity_from_parts(rel_parts, "ses-", "single-session"),
            )
        except ValueError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            continue
        if "fmap" in rel_parts:
            fmap_jsons.append(sidecar)
        if "func" in rel_parts and "_bold.json" in path.name:
            bold_jsons.append(sidecar)
    return fmap_jsons, bold_jsons


def audit_fmap_metadata(fmaps: list[JsonSidecar]) -> list[Issue]:
    issues: list[Issue] = []
    for fmap in fmaps:
        pe = fmap.data.get("PhaseEncodingDirection")
        if pe not in PE_OPPOSITES:
            issues.append(Issue("FAIL", fmap.path, "PhaseEncodingDirection", "missing or invalid"))

        trt = fmap.data.get("TotalReadoutTime")
        if not isinstance(trt, (int, float)) or not 0 < float(trt) < 0.2:
            issues.append(Issue("FAIL", fmap.path, "TotalReadoutTime", "missing or outside expected 0-0.2 s range"))

        ees = fmap.data.get("EffectiveEchoSpacing")
        if ees is not None and (not isinstance(ees, (int, float)) or float(ees) <= 0):
            issues.append(Issue("WARN", fmap.path, "EffectiveEchoSpacing", "present but non-positive or non-numeric"))

        if not as_list(fmap.data.get("B0FieldIdentifier")):
            issues.append(Issue("FAIL", fmap.path, "B0FieldIdentifier", "missing project-standard fieldmap identifier"))
    return issues


def audit_bold_sources(bolds: list[JsonSidecar], fmap_ids_by_subject: dict[str, set[str]]) -> list[Issue]:
    issues: list[Issue] = []
    for bold in bolds:
        sources = as_list(bold.data.get("B0FieldSource"))
        if not sources:
            issues.append(Issue("FAIL", bold.path, "B0FieldSource", "missing project-standard fieldmap source"))
            continue
        subject_fmap_ids = fmap_ids_by_subject.get(bold.subject, set())
        missing = [source for source in sources if source not in subject_fmap_ids]
        if missing:
            issues.append(Issue("FAIL", bold.path, "B0FieldSource", f"unknown subject-level B0FieldIdentifier(s): {', '.join(missing)}"))
    return issues


def audit_identifier_groups(fmaps: list[JsonSidecar]) -> list[Issue]:
    issues: list[Issue] = []
    groups: dict[tuple[str, str], list[JsonSidecar]] = {}
    for fmap in fmaps:
        for identifier in as_list(fmap.data.get("B0FieldIdentifier")):
            groups.setdefault((fmap.subject, identifier), []).append(fmap)

    for (subject, identifier), members in sorted(groups.items()):
        sessions = {member.session for member in members}
        if len(sessions) > 1:
            issues.append(Issue("FAIL", members[0].path, "B0FieldIdentifier", f"{subject}/{identifier}: reused across sessions; identifiers should encode session/acquisition identity"))

        directions = [member.data.get("PhaseEncodingDirection") for member in members]
        valid_directions = [direction for direction in directions if isinstance(direction, str)]
        has_opposite_pair = any(PE_OPPOSITES.get(direction) in valid_directions for direction in valid_directions)
        if len(members) < 2:
            issues.append(Issue("FAIL", members[0].path, "B0FieldIdentifier", f"{subject}/{identifier}: only one fieldmap sidecar in group"))
        elif not has_opposite_pair:
            issues.append(Issue("FAIL", members[0].path, "PhaseEncodingDirection", f"{subject}/{identifier}: no opposite AP/PA phase-encoding pair"))

        geometries: dict[tuple[tuple[int, ...], tuple[float, ...], tuple[float, ...]], list[Path]] = {}
        for member in members:
            image_path = json_to_image_path(member.path)
            if image_path is None:
                issues.append(Issue("WARN", member.path, "image", "matching NIfTI image not found for geometry check"))
                continue
            geometry = read_image_geometry(image_path)
            if geometry is None:
                continue
            geometries.setdefault(geometry, []).append(member.path)
        if len(geometries) > 1:
            issues.append(Issue("WARN", members[0].path, "geometry", f"{subject}/{identifier}: fieldmap image geometry differs within group"))
    return issues


def audit_cross_session_sources(fmaps: list[JsonSidecar], bolds: list[JsonSidecar]) -> list[Issue]:
    issues: list[Issue] = []
    fmap_lookup: dict[tuple[str, str], list[JsonSidecar]] = {}
    for fmap in fmaps:
        for identifier in as_list(fmap.data.get("B0FieldIdentifier")):
            fmap_lookup.setdefault((fmap.subject, identifier), []).append(fmap)

    for bold in bolds:
        for source in as_list(bold.data.get("B0FieldSource")):
            source_fmaps = fmap_lookup.get((bold.subject, source), [])
            for fmap in source_fmaps:
                if fmap.session != bold.session:
                    issues.append(Issue("FAIL", bold.path, "B0FieldSource", f"{source}: crosses session boundary from {bold.session} to {fmap.session}"))
    return issues


def audit_intended_for(fmaps: list[JsonSidecar], bolds: list[JsonSidecar], bids_dir: Path) -> list[Issue]:
    issues: list[Issue] = []
    bold_relpaths = {bold.path.relative_to(bids_dir).with_suffix("").as_posix() for bold in bolds}

    for fmap in fmaps:
        intended_for = as_list(fmap.data.get("IntendedFor"))
        for target in intended_for:
            normalized = target.removeprefix("./")
            compare_path = normalized.removeprefix("bids::")
            for suffix in (".nii.gz", ".nii"):
                if compare_path.endswith(suffix):
                    compare_path = compare_path[: -len(suffix)]
            uses_bids_uri = normalized.startswith("bids::")
            if not uses_bids_uri:
                issues.append(Issue("WARN", fmap.path, "IntendedFor", f"legacy/non-BIDS URI target: {target}"))
            if compare_path not in bold_relpaths:
                issues.append(Issue("WARN", fmap.path, "IntendedFor", f"target does not match a BOLD sidecar: {target}"))
    return issues


def write_report(issues: list[Issue], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["severity", "path", "field", "message"])
        writer.writeheader()
        for issue in issues:
            writer.writerow(
                {
                    "severity": issue.severity,
                    "path": str(issue.path),
                    "field": issue.field,
                    "message": issue.message,
                }
            )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bids_dir", type=Path)
    parser.add_argument("--output", type=Path, default=Path("sdc_metadata_audit.csv"))
    args = parser.parse_args()

    if not args.bids_dir.exists():
        parser.error(f"BIDS directory does not exist: {args.bids_dir}")

    fmaps, bolds = collect_sidecars(args.bids_dir)
    fmap_ids_by_subject: dict[str, set[str]] = {}
    for fmap in fmaps:
        fmap_ids_by_subject.setdefault(fmap.subject, set()).update(as_list(fmap.data.get("B0FieldIdentifier")))
    issues = []
    issues.extend(audit_fmap_metadata(fmaps))
    issues.extend(audit_bold_sources(bolds, fmap_ids_by_subject))
    issues.extend(audit_identifier_groups(fmaps))
    issues.extend(audit_cross_session_sources(fmaps, bolds))
    issues.extend(audit_intended_for(fmaps, bolds, args.bids_dir))

    write_report(issues, args.output)
    fail_count = sum(issue.severity == "FAIL" for issue in issues)
    warn_count = sum(issue.severity == "WARN" for issue in issues)
    print(f"Audited {len(fmaps)} fmap JSONs and {len(bolds)} BOLD JSONs")
    print(f"Report: {args.output}")
    print(f"FAIL={fail_count} WARN={warn_count}")
    return 1 if fail_count else 0


if __name__ == "__main__":
    raise SystemExit(main())
