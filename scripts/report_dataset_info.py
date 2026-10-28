#!/usr/bin/env python3
"""Report project-management-level inventory information for a BIDS dataset."""

from __future__ import annotations

import argparse
import csv
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


BOLD_SUFFIXES = (".nii.gz", ".nii")
GROUP_ORDER = ("patient", "HC", "unknown")
BIDS_ENTITY_PATTERN = re.compile(r"(sub|ses|task|acq|dir|run|echo)-([^_]+)")


@dataclass(frozen=True)
class RunSummary:
    subject: str
    group: str
    session: str
    task: str
    run: str
    direction: str
    echo: str
    label: str
    path: str


@dataclass(frozen=True)
class SessionSummary:
    subject: str
    group: str
    session: str
    available_folders: tuple[str, ...]
    anat_count: int
    func_run_count: int
    fmap_count: int
    dwi_count: int
    runs: tuple[RunSummary, ...]


@dataclass(frozen=True)
class SubjectSummary:
    subject: str
    group: str
    sessions: tuple[SessionSummary, ...]

    @property
    def session_count(self) -> int:
        return len(self.sessions)

    @property
    def session_names(self) -> tuple[str, ...]:
        return tuple(session.session for session in self.sessions)


def strip_bids_prefix(subject_name: str) -> str:
    if subject_name.startswith("sub-"):
        return subject_name[4:]
    return subject_name


def group_for_subject(subject_name: str) -> str:
    subject_id = strip_bids_prefix(subject_name)
    if subject_id.startswith("1"):
        return "patient"
    if subject_id.startswith("3"):
        return "HC"
    return "unknown"


def discover_sessions(subject_dir: Path) -> list[Path]:
    sessions = sorted(path for path in subject_dir.glob("ses-*") if path.is_dir())
    return sessions if sessions else [subject_dir]


def strip_nii_suffix(filename: str) -> str:
    for suffix in BOLD_SUFFIXES:
        if filename.endswith(suffix):
            return filename[: -len(suffix)]
    return filename


def parse_bids_entities(path: Path) -> dict[str, str]:
    return dict(BIDS_ENTITY_PATTERN.findall(strip_nii_suffix(path.name)))


def run_label_from_entities(entities: dict[str, str], fallback: str) -> str:
    label_parts = [
        f"{entity}-{entities[entity]}"
        for entity in ("task", "acq", "dir", "run", "echo")
        if entity in entities
    ]
    if label_parts:
        return "_".join(label_parts)
    return fallback


def count_files(data_dir: Path, patterns: tuple[str, ...]) -> int:
    if not data_dir.is_dir():
        return 0
    return sum(1 for pattern in patterns for path in data_dir.glob(pattern) if path.is_file())


def discover_available_folders(session_dir: Path) -> tuple[str, ...]:
    return tuple(sorted(path.name for path in session_dir.iterdir() if path.is_dir()))


def discover_runs(subject: str, group: str, session: str, session_dir: Path, bids_dir: Path) -> tuple[RunSummary, ...]:
    func_dir = session_dir / "func"
    if not func_dir.is_dir():
        return ()

    bold_files = sorted(
        path
        for suffix in BOLD_SUFFIXES
        for path in func_dir.glob(f"*_bold{suffix}")
        if path.is_file()
    )
    runs: list[RunSummary] = []
    for bold_file in bold_files:
        entities = parse_bids_entities(bold_file)
        label = run_label_from_entities(entities, strip_nii_suffix(bold_file.name))
        runs.append(
            RunSummary(
                subject=subject,
                group=group,
                session=session,
                task=entities.get("task", ""),
                run=entities.get("run", ""),
                direction=entities.get("dir", ""),
                echo=entities.get("echo", ""),
                label=label,
                path=str(bold_file.relative_to(bids_dir)),
            )
        )
    return tuple(runs)


def build_session_summaries(bids_dir: Path) -> list[SessionSummary]:
    summaries: list[SessionSummary] = []
    subjects = sorted(path for path in bids_dir.glob("sub-*") if path.is_dir())

    for subject_dir in subjects:
        group = group_for_subject(subject_dir.name)
        for session_dir in discover_sessions(subject_dir):
            session = session_dir.name if session_dir.name.startswith("ses-") else "single-session"
            runs = discover_runs(subject_dir.name, group, session, session_dir, bids_dir)
            summaries.append(
                SessionSummary(
                    subject=subject_dir.name,
                    group=group,
                    session=session,
                    available_folders=discover_available_folders(session_dir),
                    anat_count=count_files(session_dir / "anat", ("*.nii.gz", "*.nii")),
                    func_run_count=len(runs),
                    fmap_count=count_files(session_dir / "fmap", ("*.nii.gz", "*.nii", "*.json")),
                    dwi_count=count_files(session_dir / "dwi", ("*.nii.gz", "*.nii")),
                    runs=runs,
                )
            )

    return summaries


def build_subject_summaries(summaries: list[SessionSummary]) -> list[SubjectSummary]:
    sessions_by_subject: dict[str, list[SessionSummary]] = {}
    for summary in summaries:
        sessions_by_subject.setdefault(summary.subject, []).append(summary)

    subject_summaries = []
    for subject, subject_sessions in sorted(sessions_by_subject.items()):
        ordered_sessions = tuple(sorted(subject_sessions, key=lambda item: item.session))
        subject_summaries.append(
            SubjectSummary(
                subject=subject,
                group=ordered_sessions[0].group,
                sessions=ordered_sessions,
            )
        )
    return subject_summaries


def output_with_suffix(output: Path, suffix: str) -> Path:
    if output.suffix:
        return output.with_name(f"{output.stem}_{suffix}{output.suffix}")
    return output.with_name(f"{output.name}_{suffix}.csv")


def write_group_summary_csv(subjects: list[SubjectSummary], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=["group", "subject_count", "subjects"])
        writer.writeheader()
        for group in GROUP_ORDER:
            group_subjects = sorted(subject.subject for subject in subjects if subject.group == group)
            writer.writerow(
                {
                    "group": group,
                    "subject_count": len(group_subjects),
                    "subjects": ";".join(group_subjects),
                }
            )


def write_subject_summary_csv(subjects: list[SubjectSummary], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["subject", "group", "session_count", "sessions", "total_func_runs"],
        )
        writer.writeheader()
        for subject in subjects:
            total_func_runs = sum(session.func_run_count for session in subject.sessions)
            writer.writerow(
                {
                    "subject": subject.subject,
                    "group": subject.group,
                    "session_count": subject.session_count,
                    "sessions": ";".join(subject.session_names),
                    "total_func_runs": total_func_runs,
                }
            )


def write_session_summary_csv(summaries: list[SessionSummary], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=[
                "subject",
                "group",
                "session",
                "available_folders",
                "anat_count",
                "func_run_count",
                "fmap_count",
                "dwi_count",
                "run_labels",
            ],
        )
        writer.writeheader()
        for summary in summaries:
            writer.writerow(
                {
                    "subject": summary.subject,
                    "group": summary.group,
                    "session": summary.session,
                    "available_folders": ";".join(summary.available_folders),
                    "anat_count": summary.anat_count,
                    "func_run_count": summary.func_run_count,
                    "fmap_count": summary.fmap_count,
                    "dwi_count": summary.dwi_count,
                    "run_labels": ";".join(run.label for run in summary.runs),
                }
            )


def write_run_inventory_csv(summaries: list[SessionSummary], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=["subject", "group", "session", "task", "run", "direction", "echo", "label", "path"],
        )
        writer.writeheader()
        for summary in summaries:
            for run in summary.runs:
                writer.writerow(
                    {
                        "subject": run.subject,
                        "group": run.group,
                        "session": run.session,
                        "task": run.task,
                        "run": run.run,
                        "direction": run.direction,
                        "echo": run.echo,
                        "label": run.label,
                        "path": run.path,
                    }
                )


def write_csv_reports(summaries: list[SessionSummary], output: Path) -> list[Path]:
    subjects = build_subject_summaries(summaries)
    group_output = output_with_suffix(output, "group_summary")
    subject_output = output_with_suffix(output, "subject_summary")
    run_output = output_with_suffix(output, "run_inventory")

    write_session_summary_csv(summaries, output)
    write_group_summary_csv(subjects, group_output)
    write_subject_summary_csv(subjects, subject_output)
    write_run_inventory_csv(summaries, run_output)

    return [output, group_output, subject_output, run_output]


def completeness_flags(summary: SessionSummary) -> list[str]:
    flags = []
    if "anat" not in summary.available_folders:
        flags.append("missing anat folder")
    if "func" not in summary.available_folders:
        flags.append("missing func folder")
    elif summary.func_run_count == 0:
        flags.append("no BOLD runs")
    if "fmap" not in summary.available_folders:
        flags.append("missing fmap folder")
    return flags


def print_report(summaries: list[SessionSummary], bids_dir: Path) -> None:
    subjects = build_subject_summaries(summaries)

    print(f"Dataset: {bids_dir}")
    print(f"Generated: {datetime.now().isoformat(timespec='seconds')}")
    print()
    print("Dataset overview")
    print(f"- Total subjects: {len(subjects)}")
    print(f"- Total sessions: {len(summaries)}")
    print(f"- Total functional runs: {sum(summary.func_run_count for summary in summaries)}")
    print()
    print("Subjects by group")
    for group in GROUP_ORDER:
        group_subjects = sorted(subject.subject for subject in subjects if subject.group == group)
        listed_subjects = ", ".join(group_subjects) if group_subjects else "none"
        print(f"- {group}: {len(group_subjects)} ({listed_subjects})")
    print()
    print("Subject/session/run inventory")

    for subject in subjects:
        session_names = ", ".join(subject.session_names)
        print(f"- {subject.subject} ({subject.group}): {subject.session_count} session(s): {session_names}")
        for summary in subject.sessions:
            folders = ", ".join(summary.available_folders) if summary.available_folders else "none"
            flags = completeness_flags(summary)
            flag_text = f" | flags: {', '.join(flags)}" if flags else ""
            print(
                f"  - {summary.session}: folders={folders}; "
                f"anat={summary.anat_count}; func_runs={summary.func_run_count}; "
                f"fmap={summary.fmap_count}; dwi={summary.dwi_count}{flag_text}"
            )
            if summary.runs:
                for run in summary.runs:
                    print(f"    - {run.label}: {run.path}")
            else:
                print("    - runs: none")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog=(
            "Hyak usage: scripts/run_dataset_info_report_hyak.sh "
            "config/mri_preproc.env"
        ),
    )
    parser.add_argument("bids_dir", type=Path, help="Path to the BIDS dataset root containing sub-* folders.")
    parser.add_argument(
        "--csv",
        type=Path,
        help=(
            "Optional path for a session-level CSV report. Companion group, "
            "subject, and run CSVs are written next to it."
        ),
    )
    args = parser.parse_args()

    if not args.bids_dir.exists():
        parser.error(f"BIDS directory does not exist: {args.bids_dir}")
    if not args.bids_dir.is_dir():
        parser.error(f"BIDS path is not a directory: {args.bids_dir}")

    summaries = build_session_summaries(args.bids_dir)
    if not summaries:
        parser.error(f"No sub-* directories found in BIDS directory: {args.bids_dir}")

    print_report(summaries, args.bids_dir)

    if args.csv:
        csv_outputs = write_csv_reports(summaries, args.csv)
        print()
        print("Wrote CSV reports:")
        for csv_output in csv_outputs:
            print(f"- {csv_output}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
