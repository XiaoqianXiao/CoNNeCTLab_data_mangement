#!/usr/bin/env python3
"""Write a manifest of BOLD-bearing BIDS sessions or subjects for Stage-B jobs."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path


def discover_rows(bids_dir: Path, session_labels: set[str]) -> list[tuple[str, str]]:
    """Return BIDS subject/session pairs that contain at least one BOLD image."""
    rows: list[tuple[str, str]] = []
    for subject_dir in sorted(path for path in bids_dir.glob("sub-*") if path.is_dir()):
        sessions = sorted(path for path in subject_dir.glob("ses-*") if path.is_dir())
        if not sessions:
            sessions = [subject_dir]
        for session_dir in sessions:
            if session_labels and session_dir.name not in session_labels:
                continue
            has_bold = any((session_dir / "func").glob("*_bold.nii*"))
            if has_bold:
                session = session_dir.name if session_dir.name.startswith("ses-") else "single-session"
                rows.append((subject_dir.name, session))
    return rows


def discover_subjects(bids_dir: Path, session_labels: set[str]) -> list[str]:
    """Return each subject with at least one BOLD-bearing session exactly once."""
    return sorted({subject for subject, _ in discover_rows(bids_dir, session_labels)})


def main() -> int:
    """Parse arguments, discover BOLD-bearing sessions, and write CSV output."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bids_dir", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--session-label",
        action="append",
        default=[],
        help="Restrict rows to this BIDS session label (for example, ses-baseline). Repeat as needed.",
    )
    parser.add_argument(
        "--subjects-only",
        action="store_true",
        help="Write one row per BOLD-bearing subject rather than one per subject/session.",
    )
    parser.add_argument("--no-header", action="store_true", help="Do not write the CSV header row.")
    args = parser.parse_args()

    if not args.bids_dir.is_dir():
        parser.error(f"BIDS directory does not exist: {args.bids_dir}")
    session_labels = set(args.session_label)
    rows = discover_rows(args.bids_dir, session_labels)
    if not rows:
        selected = f" for requested sessions: {', '.join(sorted(session_labels))}" if session_labels else ""
        parser.error(f"No BOLD-bearing subject/session pairs found{selected}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        if args.subjects_only:
            subjects = discover_subjects(args.bids_dir, session_labels)
            if not args.no_header:
                writer.writerow(("subject",))
            writer.writerows((subject,) for subject in subjects)
            print(f"Wrote {len(subjects)} BOLD-bearing subject rows to {args.output}")
        else:
            if not args.no_header:
                writer.writerow(("subject", "session"))
            writer.writerows(rows)
            print(f"Wrote {len(rows)} subject/session rows to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
