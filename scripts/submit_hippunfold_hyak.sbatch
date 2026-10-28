#!/usr/bin/env bash
#SBATCH --job-name=r01-hippunfold
#SBATCH --account=fang
#SBATCH --partition=ckpt-all
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=48:00:00

set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: sbatch [SLURM_OPTIONS] scripts/submit_hippunfold_hyak.sbatch CONFIG_ENV [SUBJECT_LIST]"
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
mkdir -p "$LOG_DIR" "${HIPPUNFOLD_OUT:-${DERIVATIVES_DIR}/hippunfold}" "${HIPPUNFOLD_WORK:-${WORK_ROOT:-${SCRUBBED_PROJECT_DIR}/scratch}/hippunfold}" "${HIPPUNFOLD_CACHE_DIR:-${SCRUBBED_PROJECT_DIR}/cache/hippunfold}"
snakebids_marker="${HIPPUNFOLD_OUT:-${DERIVATIVES_DIR}/hippunfold}/.snakebids"
if [[ ! -s "$snakebids_marker" ]]; then
  tmp_marker="${snakebids_marker}.tmp.$$"
  printf '%s\n' '{"mode":"bidsapp"}' > "$tmp_marker"
  mv "$tmp_marker" "$snakebids_marker"
fi

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
  export HIPPUNFOLD_SINGLE_SUBJECT="$subject"
fi

if [[ "${HIPPUNFOLD_STAGE_FROM_KOPAH:-0}" == "1" ]]; then
  [[ -n "${HIPPUNFOLD_SINGLE_SUBJECT:-}" ]] || { echo "ERROR: Kopah staging requires one subject per task." >&2; exit 2; }
  branch_stage_root="${KOPAH_BRANCH_STAGE_ROOT}/${SLURM_JOB_ID:-manual}/hippunfold"
  "${REPO_DIR}/scripts/stage_kopah_bids_subject.sh" "$KOPAH_BIDS_URI" "${branch_stage_root}/bids" "$HIPPUNFOLD_SINGLE_SUBJECT" "$KOPAH_S3CFG"
  export KOPAH_STAGED_BIDS_DIR="${branch_stage_root}/bids"
fi

export OMP_NUM_THREADS="${OMP_NTHREADS:-1}"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${OMP_NTHREADS:-1}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export LD_PRELOAD="${LD_PRELOAD:-}"

if command -v module >/dev/null 2>&1; then
  module purge || true
  module load apptainer || module load singularity || true
fi

echo "Running on host: $(hostname)"
echo "SLURM_JOB_ID=${SLURM_JOB_ID:-NA}"
echo "SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:-NA}"
echo "CONFIG_ENV=$CONFIG_ENV"
echo "HIPPUNFOLD_SINGLE_SUBJECT=${HIPPUNFOLD_SINGLE_SUBJECT:-}"

"${REPO_DIR}/scripts/run_hippunfold.sh" "$CONFIG_ENV"

if [[ "${KOPAH_PUBLISH_BRANCH_OUTPUTS:-0}" == "1" ]]; then
  [[ -n "${HIPPUNFOLD_SINGLE_SUBJECT:-}" ]] || { echo "ERROR: Kopah publication requires one subject per task." >&2; exit 2; }
  "${REPO_DIR}/scripts/sync_kopah.sh" push "${HIPPUNFOLD_OUT}/${HIPPUNFOLD_SINGLE_SUBJECT}" "${KOPAH_DERIVATIVES_URI%/}/hippunfold/${HIPPUNFOLD_SINGLE_SUBJECT}" --s3cfg "$KOPAH_S3CFG"
  if [[ "${KOPAH_REMOVE_LOCAL_BRANCH_OUTPUT:-0}" == "1" ]]; then
    rm -rf "${HIPPUNFOLD_OUT:?}/${HIPPUNFOLD_SINGLE_SUBJECT}"
    if [[ "${HIPPUNFOLD_STAGE_FROM_KOPAH:-0}" == "1" ]]; then rm -rf "$branch_stage_root"; fi
  fi
fi
