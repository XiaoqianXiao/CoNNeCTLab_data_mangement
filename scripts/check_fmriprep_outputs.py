#!/usr/bin/env python3
"""Check that canonical fMRIPrep outputs from the preservation plan exist."""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path

from freesurfer_subject import FreeSurferSubjectResolutionError, resolve_freesurfer_subject


@dataclass(frozen=True)
class Check:
    participant: str
    category: str
    pattern: str
    count: int
    status: str


def participant_dirs(fmriprep_dir: Path, labels: list[str]) -> list[Path]:
    if labels:
        return [fmriprep_dir / label if label.startswith("sub-") else fmriprep_dir / f"sub-{label}" for label in labels]
    return sorted(path for path in fmriprep_dir.glob("sub-*") if path.is_dir())


def count_matches(root: Path, pattern: str) -> int:
    return sum(1 for _ in root.glob(pattern))


def count_native_t1w_matches(root: Path, pattern: str) -> int:
    """Count primary T1w derivatives, excluding standard-space T1w copies."""
    return sum(1 for path in root.glob(pattern) if "_space-" not in path.name)


def build_checks(fmriprep_dir: Path, freesurfer_dir: Path, labels: list[str]) -> list[Check]:
    checks: list[Check] = []
    patterns = [
        ("html_report", "{participant}.html"),
        ("confounds_tsv", "{participant}/**/*desc-confounds_timeseries.tsv"),
        ("confounds_json", "{participant}/**/*desc-confounds_timeseries.json"),
        ("boldref", "{participant}/**/*_boldref.nii.gz"),
        ("native_func_bold", "{participant}/**/*space-func*_desc-preproc_bold.nii.gz"),
        ("t1w_bold", "{participant}/**/*space-T1w*_desc-preproc_bold.nii.gz"),
        ("mni2009c_res_native_bold", "{participant}/**/*space-MNI152NLin2009cAsym*_res-native*_desc-preproc_bold.nii.gz"),
        ("fsnative_gifti", "{participant}/**/*space-fsnative*_bold.func.gii"),
        ("cifti_91k", "{participant}/**/*space-fsLR*_den-91k*_bold.dtseries.nii"),
        ("xfm_bold_to_t1w", "{participant}/**/*from-boldref*_to-T1w*_xfm.*"),
        ("xfm_t1w_to_mni", "{participant}/**/*from-T1w*_to-MNI152NLin2009cAsym*_xfm.*"),
    ]

    for participant_dir in participant_dirs(fmriprep_dir, labels):
        participant = participant_dir.name
        for category, pattern_template in patterns:
            pattern = pattern_template.format(participant=participant)
            count = count_matches(fmriprep_dir, pattern)
            checks.append(Check(participant, category, pattern, count, "PASS" if count > 0 else "MISSING"))

        shared_t1w_pattern = f"{participant}/anat/*desc-preproc_T1w.nii.gz"
        shared_t1w_count = count_native_t1w_matches(fmriprep_dir, shared_t1w_pattern)
        checks.append(
            Check(
                participant,
                "shared_preproc_t1w",
                shared_t1w_pattern,
                shared_t1w_count,
                "PASS" if shared_t1w_count == 1 else "MISSING_OR_AMBIGUOUS",
            )
        )

        session_anat_count = sum(1 for _ in participant_dir.glob("ses-*/anat"))
        checks.append(
            Check(
                participant,
                "session_anat_directories",
                f"{participant}/ses-*/anat",
                session_anat_count,
                "PASS" if session_anat_count == 0 else "UNEXPECTED",
            )
        )

        try:
            resolved = resolve_freesurfer_subject(freesurfer_dir, participant)
        except FreeSurferSubjectResolutionError as exc:
            candidates = count_matches(freesurfer_dir, f"{participant}_*")
            status = "MISSING" if candidates == 0 else "AMBIGUOUS"
            checks.append(Check(participant, "freesurfer_subject", str(exc), candidates, status))
        else:
            checks.append(Check(participant, "freesurfer_subject", resolved.name, 1, "PASS"))
    return checks


def write_checks(checks: list[Check], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["participant", "category", "pattern", "count", "status"])
        writer.writeheader()
        for check in checks:
            writer.writerow(check.__dict__)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fmriprep-dir", type=Path, required=True)
    parser.add_argument("--freesurfer-dir", type=Path, required=True)
    parser.add_argument("--participant-label", nargs="*", default=[])
    parser.add_argument("--output", type=Path, default=Path("fmriprep_output_check.csv"))
    args = parser.parse_args()

    checks = build_checks(args.fmriprep_dir, args.freesurfer_dir, args.participant_label)
    write_checks(checks, args.output)
    missing = [check for check in checks if check.status != "PASS"]
    print(f"Wrote {len(checks)} checks to {args.output}")
    print(f"Missing checks: {len(missing)}")
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
