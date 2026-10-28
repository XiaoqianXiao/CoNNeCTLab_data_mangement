#!/usr/bin/env bash
#SBATCH --job-name=r01-first
#SBATCH --account=fang
#SBATCH --partition=ckpt-all
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=12:00:00
#SBATCH --output=/gscratch/scrubbed/fanglab/xiaoqian/IFOCUS/logs/slurm/first/first_%A_%a.out
#SBATCH --error=/gscratch/scrubbed/fanglab/xiaoqian/IFOCUS/logs/slurm/first/first_%A_%a.err

set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: sbatch [SLURM_OPTIONS] scripts/submit_first_hyak.sbatch CONFIG_ENV [SUBJECT_LIST]"
  exit 0
fi

CONFIG_ENV="$1"
SUBJECT_LIST="${2:-}"
REPO_DIR="${SLURM_SUBMIT_DIR:-$(pwd)}"
cd "$REPO_DIR"

if [[ "$CONFIG_ENV" != /* ]]; then
  CONFIG_ENV="${REPO_DIR}/${CONFIG_ENV}"
fi
if [[ -n "$SUBJECT_LIST" && "$SUBJECT_LIST" != /* ]]; then
  SUBJECT_LIST="${REPO_DIR}/${SUBJECT_LIST}"
fi

# shellcheck source=/dev/null
source "$CONFIG_ENV"
mkdir -p "$LOG_DIR" "${FIRST_OUT:-${DERIVATIVES_DIR}/first}" "${FIRST_WORK:-${WORK_ROOT:-${SCRUBBED_PROJECT_DIR}/scratch}/first}"

if [[ -n "$SUBJECT_LIST" ]]; then
  if [[ -z "${SLURM_ARRAY_TASK_ID:-}" ]]; then
    echo "ERROR: SUBJECT_LIST was provided, but SLURM_ARRAY_TASK_ID is not set." >&2
    exit 2
  fi
  subject="$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" "$SUBJECT_LIST")"
  if [[ -z "$subject" ]]; then
    echo "ERROR: no subject found for array index ${SLURM_ARRAY_TASK_ID}" >&2
    exit 2
  fi
  export FIRST_SINGLE_SUBJECT="$subject"
fi

if [[ "${FIRST_STAGE_FROM_KOPAH:-0}" == "1" ]]; then
  [[ -n "${FIRST_SINGLE_SUBJECT:-}" ]] || { echo "ERROR: Kopah staging requires one subject per task." >&2; exit 2; }
  branch_stage_root="${KOPAH_BRANCH_STAGE_ROOT}/${SLURM_JOB_ID:-manual}/first"
  "${REPO_DIR}/scripts/sync_kopah.sh" pull "${KOPAH_DERIVATIVES_URI%/}/fmriprep/${FIRST_SINGLE_SUBJECT}" "${branch_stage_root}/fmriprep/${FIRST_SINGLE_SUBJECT}" --s3cfg "$KOPAH_S3CFG"
  export KOPAH_STAGED_FMRIPREP_OUT="${branch_stage_root}/fmriprep"
fi

if command -v module >/dev/null 2>&1; then
  module purge || true
  module load apptainer || module load singularity || true
fi

echo "Running on host: $(hostname)"
echo "SLURM_JOB_ID=${SLURM_JOB_ID:-NA}"
echo "SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:-NA}"
echo "CONFIG_ENV=$CONFIG_ENV"
echo "FIRST_SINGLE_SUBJECT=${FIRST_SINGLE_SUBJECT:-}"

"${REPO_DIR}/scripts/run_first.sh" "$CONFIG_ENV"

if [[ "${KOPAH_PUBLISH_BRANCH_OUTPUTS:-0}" == "1" ]]; then
  [[ -n "${FIRST_SINGLE_SUBJECT:-}" ]] || { echo "ERROR: Kopah publication requires one subject per task." >&2; exit 2; }
  "${REPO_DIR}/scripts/sync_kopah.sh" push "${FIRST_OUT}/${FIRST_SINGLE_SUBJECT}" "${KOPAH_DERIVATIVES_URI%/}/first/${FIRST_SINGLE_SUBJECT}" --s3cfg "$KOPAH_S3CFG"
  if [[ "${KOPAH_REMOVE_LOCAL_BRANCH_OUTPUT:-0}" == "1" ]]; then
    rm -rf "${FIRST_OUT:?}/${FIRST_SINGLE_SUBJECT}"
    if [[ "${FIRST_STAGE_FROM_KOPAH:-0}" == "1" ]]; then rm -rf "$branch_stage_root"; fi
  fi
fi
