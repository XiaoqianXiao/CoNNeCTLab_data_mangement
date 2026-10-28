#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/submit_fmriprep_onestep_array_hyak.sh CONFIG_ENV [SUBJECT_ID ...]

Submit one all-in-one fMRIPrep job per subject. Each job processes the
subject's anatomical and functional data together, with all sessions visible
to fMRIPrep. This is an alternative to the separate Stage-A and Stage-B
workflow and writes directly to FMRIPREP_OUT.

When SUBJECT_ID values are supplied, submit only those BIDS subjects (for
example, sub-305). Without subject IDs, submit every sub-* directory in
BIDS_DIR.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi
if (( $# < 1 )); then
  usage >&2
  exit 2
fi

config_env="$1"
shift
requested_subjects=("$@")
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
[[ "$config_env" = /* ]] || config_env="$repo_dir/$config_env"
# shellcheck source=/dev/null
source "$config_env"

for required in BIDS_DIR FMRIPREP_OUT FS_SUBJECTS_DIR WORK_DIR LOG_DIR FS_LICENSE \
  FMRIPREP_IMAGE CONTAINER_RUNTIME HYAK_ACCOUNT HYAK_PARTITION \
  FMRIPREP_ONESTEP_CPUS FMRIPREP_ONESTEP_MEM_MB; do
  [[ -n "${!required:-}" ]] || { echo "ERROR: $required is not set in $config_env" >&2; exit 2; }
done

mkdir -p "$LOG_DIR" "${LOG_ROOT:?ERROR: LOG_ROOT must be set in the config}/slurm/fmriprep"
[[ -d "$BIDS_DIR" ]] || { echo "ERROR: BIDS_DIR does not exist: $BIDS_DIR" >&2; exit 2; }

if [[ -z "${TEMPLATEFLOW_HOME:-}" ]]; then
  TEMPLATEFLOW_HOME="/gscratch/fang/templateflow"
fi
required_template="${TEMPLATEFLOW_HOME}/tpl-MNI152NLin6Asym/tpl-MNI152NLin6Asym_res-01_T1w.nii.gz"
if [[ ! -s "$required_template" ]]; then
  echo "ERROR: TemplateFlow cache is not ready for offline Hyak fMRIPrep jobs." >&2
  echo "Missing or empty required file: $required_template" >&2
  exit 2
fi

subject_list="$LOG_DIR/fmriprep_onestep_subjects_$(date +%Y%m%d_%H%M%S).txt"
if (( ${#requested_subjects[@]} )); then
  for subject in "${requested_subjects[@]}"; do
    [[ "$subject" =~ ^sub-[^/]+$ ]] || {
      echo "ERROR: invalid BIDS subject ID: $subject (expected sub-*)" >&2
      exit 2
    }
    [[ -d "$BIDS_DIR/$subject" ]] || {
      echo "ERROR: BIDS subject directory does not exist: $BIDS_DIR/$subject" >&2
      exit 2
    }
  done
  printf '%s\n' "${requested_subjects[@]}" | sort -u > "$subject_list"
else
  "$repo_dir/scripts/run_python_hyak.sh" "$config_env" \
    "$repo_dir/scripts/make_fmriprep_session_manifest.py" \
    "$BIDS_DIR" --subjects-only --no-header --output "$subject_list"
fi

subject_count="$(wc -l < "$subject_list" | tr -d ' ')"
[[ "$subject_count" -gt 0 ]] || { echo "ERROR: no BIDS subjects found or requested" >&2; exit 2; }

concurrency="${FMRIPREP_ONESTEP_ARRAY_CONCURRENCY:-1}"
[[ "$concurrency" =~ ^[0-9]+$ ]] || { echo "ERROR: invalid one-step array concurrency" >&2; exit 2; }
array_spec="0-$((subject_count - 1))"
if [[ "$concurrency" != "0" ]]; then
  array_spec+="%${concurrency}"
fi

time_args=()
if [[ -n "${FMRIPREP_ONESTEP_TIME:-}" ]]; then
  time_args=(--time="$FMRIPREP_ONESTEP_TIME")
fi

echo "Submitting $subject_count one-step fMRIPrep jobs to $HYAK_PARTITION"
sbatch \
  --account="$HYAK_ACCOUNT" \
  --partition="$HYAK_PARTITION" \
  "${time_args[@]}" \
  --cpus-per-task="$FMRIPREP_ONESTEP_CPUS" \
  --mem="${FMRIPREP_ONESTEP_MEM_MB}M" \
  --array="$array_spec" \
  --output="${LOG_ROOT}/slurm/fmriprep/fmriprep_%A_%a.out" \
  --error="${LOG_ROOT}/slurm/fmriprep/fmriprep_%A_%a.err" \
  "$repo_dir/scripts/submit_fmriprep_hyak.sbatch" "$config_env" "$subject_list"
