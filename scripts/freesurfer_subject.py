#!/usr/bin/env python3
"""Resolve one fMRIPrep FreeSurfer directory for a BIDS participant."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


class FreeSurferSubjectResolutionError(RuntimeError):
    """Raised when a participant cannot be mapped to one reconstruction."""


def resolve_freesurfer_subject(subjects_dir: Path, participant: str) -> Path:
    """Return the canonical or sole session-suffixed FreeSurfer directory.

    fMRIPrep may retain the session label in the FreeSurfer subject ID when a
    participant has a single T1w session. An exact BIDS-subject directory is
    preferred when present; otherwise exactly one ``sub-<id>_*`` directory is
    accepted. Multiple suffixed candidates require release-manager review.
    """
    if not participant.startswith("sub-"):
        raise ValueError(f"Participant must start with 'sub-': {participant}")
    if not subjects_dir.is_dir():
        raise FreeSurferSubjectResolutionError(
            f"FreeSurfer subjects directory does not exist: {subjects_dir}"
        )

    exact = subjects_dir / participant
    if exact.is_dir():
        return exact

    candidates = sorted(
        path for path in subjects_dir.glob(f"{participant}_*") if path.is_dir()
    )
    if len(candidates) == 1:
        return candidates[0]
    if not candidates:
        raise FreeSurferSubjectResolutionError(
            f"No FreeSurfer output for {participant} in {subjects_dir}; expected "
            f"{participant} or one {participant}_* directory"
        )
    names = ", ".join(path.name for path in candidates)
    raise FreeSurferSubjectResolutionError(
        f"Ambiguous FreeSurfer outputs for {participant} in {subjects_dir}: {names}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--subjects-dir", type=Path, required=True)
    parser.add_argument("--participant", required=True)
    parser.add_argument("--provenance-output", type=Path)
    args = parser.parse_args()

    try:
        resolved = resolve_freesurfer_subject(args.subjects_dir, args.participant)
    except (ValueError, FreeSurferSubjectResolutionError) as exc:
        parser.error(str(exc))

    if args.provenance_output:
        args.provenance_output.parent.mkdir(parents=True, exist_ok=True)
        args.provenance_output.write_text(
            json.dumps(
                {
                    "participant_id": args.participant,
                    "freesurfer_subject_id": resolved.name,
                    "freesurfer_source_directory": str(resolved),
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
    print(resolved)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
