#!/usr/bin/env python3
"""Canonicalize fMRIPrep anatomy into each subject's shared ``anat`` directory.

fMRIPrep derivatives used by downstream branches must expose one anatomical
reference per subject at ``sub-<label>/anat``.  Some runs instead leave a
single anatomy collection under ``sub-<label>/ses-<label>/anat``.  This tool
moves that collection to the shared location, removes the session entity from
the filenames, and records its source.  It never chooses among multiple
session-level T1w candidates.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
from pathlib import Path


T1W_PATTERN = "*desc-preproc_T1w.nii.gz"
SESSION_ANAT_GLOB = "ses-*/anat"


class SharedAnatomyError(RuntimeError):
    """Raised when a unique shared anatomical reference cannot be established."""


def t1w_candidates(anat_dir: Path) -> list[Path]:
    """Return primary native-space T1w derivatives, excluding standard-space copies."""
    return sorted(
        path
        for path in anat_dir.glob(T1W_PATTERN)
        if path.is_file() and "_space-" not in path.name
    )


def remove_session_entity(filename: str, session: str) -> str:
    entity = f"_{session}"
    if entity not in filename:
        raise SharedAnatomyError(
            f"Session anatomy filename does not contain {entity}: {filename}"
        )
    return filename.replace(entity, "", 1)


def remove_session_anatomy(subject_dir: Path) -> None:
    for session_anat_dir in sorted(subject_dir.glob(SESSION_ANAT_GLOB)):
        if session_anat_dir.is_dir():
            shutil.rmtree(session_anat_dir)


def materialize_subject(subject_dir: Path) -> None:
    """Ensure ``subject_dir/anat`` is the sole, session-free anatomy collection."""
    subject = subject_dir.name
    shared_anat_dir = subject_dir / "anat"
    shared_candidates = t1w_candidates(shared_anat_dir) if shared_anat_dir.is_dir() else []
    if len(shared_candidates) > 1:
        raise SharedAnatomyError(
            f"{subject}: multiple shared T1w candidates in {shared_anat_dir}: "
            + ", ".join(str(path) for path in shared_candidates)
        )

    if len(shared_candidates) == 1:
        if any("_ses-" in path.name for path in shared_anat_dir.iterdir() if path.is_file()):
            raise SharedAnatomyError(
                f"{subject}: shared anatomy filenames must not contain a ses- entity"
            )
        remove_session_anatomy(subject_dir)
        return

    session_candidates: list[Path] = []
    for session_anat_dir in sorted(subject_dir.glob(SESSION_ANAT_GLOB)):
        session_candidates.extend(t1w_candidates(session_anat_dir))

    if len(session_candidates) == 0:
        raise SharedAnatomyError(
            f"{subject}: no shared or session-level {T1W_PATTERN} candidate found"
        )
    if len(session_candidates) > 1:
        raise SharedAnatomyError(
            f"{subject}: found {len(session_candidates)} session-level T1w candidates; "
            "a shared unbiased anatomy must be produced by fMRIPrep rather than "
            "selecting one session arbitrarily: "
            + ", ".join(str(path) for path in session_candidates)
        )

    source_t1w = session_candidates[0]
    source_anat_dir = source_t1w.parent
    session = source_anat_dir.parent.name
    if not re.fullmatch(r"ses-[^/]+", session):
        raise SharedAnatomyError(f"{subject}: invalid session directory: {session}")
    if shared_anat_dir.exists():
        raise SharedAnatomyError(
            f"{subject}: {shared_anat_dir} exists but has no unique shared T1w candidate"
        )

    shared_anat_dir.mkdir()
    moved: list[dict[str, str]] = []
    for source in sorted(source_anat_dir.iterdir()):
        if not source.is_file():
            continue
        target = shared_anat_dir / remove_session_entity(source.name, session)
        if target.exists():
            raise SharedAnatomyError(f"{subject}: refusing to overwrite {target}")
        shutil.move(str(source), str(target))
        moved.append({"source": str(source), "target": str(target)})

    provenance = shared_anat_dir / f"{subject}_desc-sharedanatomy_provenance.json"
    provenance.write_text(
        json.dumps(
            {"source_session": session, "source_t1w": str(source_t1w), "moved_files": moved},
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    remove_session_anatomy(subject_dir)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fmriprep-dir", type=Path, required=True)
    parser.add_argument("--participant-label", action="append", default=[])
    args = parser.parse_args()

    if not args.fmriprep_dir.is_dir():
        parser.error(f"fMRIPrep directory does not exist: {args.fmriprep_dir}")
    labels = [label if label.startswith("sub-") else f"sub-{label}" for label in args.participant_label]
    subject_dirs = [args.fmriprep_dir / label for label in labels] if labels else sorted(args.fmriprep_dir.glob("sub-*"))
    if not subject_dirs:
        parser.error(f"no sub-* directories found in {args.fmriprep_dir}")
    for subject_dir in subject_dirs:
        if not subject_dir.is_dir():
            raise SharedAnatomyError(f"subject directory does not exist: {subject_dir}")
        materialize_subject(subject_dir)
        print(f"{subject_dir.name}: shared anatomy ready")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
