#!/usr/bin/env python3
"""Create a subject/session manifest for the multi-session fMRIPrep release."""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class SessionRecord:
    subject: str
    session: str
    has_anat: bool
    has_func: bool
    has_fmap: bool
    anat_files: int
    bold_files: int
    fmap_files: int


def count_files(path: Path, patterns: tuple[str, ...]) -> int:
    return sum(1 for pattern in patterns for _ in path.glob(pattern))


def discover_sessions(subject_dir: Path) -> list[Path]:
    sessions = sorted(path for path in subject_dir.glob("ses-*") if path.is_dir())
    return sessions if sessions else [subject_dir]


def build_records(bids_dir: Path) -> list[SessionRecord]:
    records: list[SessionRecord] = []
    subjects = sorted(path for path in bids_dir.glob("sub-*") if path.is_dir())
    for subject_dir in subjects:
        for session_dir in discover_sessions(subject_dir):
            anat_root = session_dir / "anat"
            func_root = session_dir / "func"
            fmap_root = session_dir / "fmap"
            anat_files = count_files(anat_root, ("*_T1w.nii.gz", "*_T1w.nii", "*_T2w.nii.gz", "*_T2w.nii"))
            bold_files = count_files(func_root, ("*_bold.nii.gz", "*_bold.nii"))
            fmap_files = count_files(fmap_root, ("*.nii.gz", "*.nii"))
            records.append(
                SessionRecord(
                    subject=subject_dir.name,
                    session=session_dir.name if session_dir.name.startswith("ses-") else "single-session",
                    has_anat=anat_files > 0,
                    has_func=bold_files > 0,
                    has_fmap=fmap_files > 0,
                    anat_files=anat_files,
                    bold_files=bold_files,
                    fmap_files=fmap_files,
                )
            )
    return records


def write_manifest(records: list[SessionRecord], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "subject",
                "session",
                "has_anat",
                "has_func",
                "has_fmap",
                "anat_files",
                "bold_files",
                "fmap_files",
            ],
        )
        writer.writeheader()
        for record in records:
            writer.writerow(record.__dict__)


def write_subject_list(records: list[SessionRecord], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    subjects = sorted({record.subject for record in records})
    output.write_text("\n".join(subjects) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bids_dir", type=Path)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--subject-list", type=Path, required=True)
    args = parser.parse_args()

    if not args.bids_dir.exists():
        parser.error(f"BIDS directory does not exist: {args.bids_dir}")

    records = build_records(args.bids_dir)
    if not records:
        parser.error(f"No sub-* directories found in BIDS directory: {args.bids_dir}")

    write_manifest(records, args.manifest)
    write_subject_list(records, args.subject_list)
    subject_count = len({record.subject for record in records})
    session_count = len(records)
    print(f"Wrote subject list: {args.subject_list}")
    print(f"Wrote session manifest: {args.manifest}")
    print(f"Subjects: {subject_count}")
    print(f"Subject/session rows: {session_count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
