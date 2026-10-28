#!/usr/bin/env bash
#SBATCH --job-name=r01-hcp-struct
#SBATCH --account=fang
#SBATCH --partition=ckpt-all
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=72:00:00

set -euo pipefail
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export LD_PRELOAD="${LD_PRELOAD:-}"

usage() {
  cat <<'USAGE'
Usage:
  sbatch [SLURM_OPTIONS] scripts/submit_hcp_structural_hyak.sbatch CONFIG_ENV [SUBJECT_LIST]

Runs one HCP structural preprocessing worker. With SUBJECT_LIST and a SLURM
array, each task runs one subject.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 || $# -gt 2 ]]; then
  usage
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

HCP_STRUCTURAL_OUT="${HCP_STRUCTURAL_OUT:-${DERIVATIVES_DIR}/hcp}"
HCP_STRUCTURAL_WORK="${HCP_STRUCTURAL_WORK:-${WORK_ROOT:-${SCRUBBED_PROJECT_DIR}/scratch}/hcp-structural}"
mkdir -p "$LOG_DIR" "$HCP_STRUCTURAL_OUT" "$HCP_STRUCTURAL_WORK"

if [[ -n "$SUBJECT_LIST" ]]; then
  if [[ -z "${SLURM_ARRAY_TASK_ID:-}" ]]; then
    echo "ERROR: SUBJECT_LIST was provided, but SLURM_ARRAY_TASK_ID is not set." >&2
    exit 2
  fi
  if [[ ! -f "$SUBJECT_LIST" ]]; then
    echo "ERROR: subject list not found: $SUBJECT_LIST" >&2
    exit 2
  fi
  subject="$(sed -n "$((SLURM_ARRAY_TASK_ID + 1))p" "$SUBJECT_LIST")"
  if [[ -z "$subject" ]]; then
    echo "ERROR: no subject found for array index ${SLURM_ARRAY_TASK_ID}" >&2
    exit 2
  fi
  export HCP_STRUCTURAL_SINGLE_SUBJECT="$subject"
fi

if [[ "${KOPAH_STAGE_BRANCHES:-0}" == "1" ]]; then
  [[ -n "${HCP_STRUCTURAL_SINGLE_SUBJECT:-}" ]] || { echo "ERROR: Kopah staging requires one subject per task." >&2; exit 2; }
  branch_stage_root="${KOPAH_BRANCH_STAGE_ROOT}/${SLURM_JOB_ID:-manual}/hcp_structural"
  "${REPO_DIR}/scripts/stage_kopah_bids_subject.sh" "$KOPAH_BIDS_URI" "${branch_stage_root}/bids" "$HCP_STRUCTURAL_SINGLE_SUBJECT" "$KOPAH_S3CFG"
  export KOPAH_STAGED_BIDS_DIR="${branch_stage_root}/bids"
fi

export OMP_NUM_THREADS="${OMP_NTHREADS:-8}"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${OMP_NTHREADS:-8}"

if command -v module >/dev/null 2>&1; then
  module purge || true
  module load apptainer || module load singularity || true
fi

if ! command -v apptainer >/dev/null 2>&1 && ! command -v singularity >/dev/null 2>&1; then
  echo "ERROR: Apptainer/Singularity is not available on this Hyak node." >&2
  exit 127
fi

if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
  echo "ERROR: Docker is not appropriate for Hyak jobs. Set CONTAINER_RUNTIME=apptainer or singularity." >&2
  exit 2
fi

echo "Running on host: $(hostname)"
echo "SLURM_JOB_ID=${SLURM_JOB_ID:-NA}"
echo "SLURM_ARRAY_TASK_ID=${SLURM_ARRAY_TASK_ID:-NA}"
echo "CONFIG_ENV=$CONFIG_ENV"
echo "HCP_STRUCTURAL_SINGLE_SUBJECT=${HCP_STRUCTURAL_SINGLE_SUBJECT:-}"

"${REPO_DIR}/scripts/run_hcp_structural.sh" "$CONFIG_ENV"

if [[ "${KOPAH_PUBLISH_BRANCH_OUTPUTS:-0}" == "1" ]]; then
  [[ -n "${HCP_STRUCTURAL_SINGLE_SUBJECT:-}" ]] || { echo "ERROR: Kopah publication requires one subject per task." >&2; exit 2; }
  hcp_subject="${HCP_STRUCTURAL_SINGLE_SUBJECT#sub-}"
  "${REPO_DIR}/scripts/sync_kopah.sh" push "${HCP_STRUCTURAL_OUT}/${hcp_subject}" "${KOPAH_DERIVATIVES_URI%/}/hcp/${hcp_subject}" --s3cfg "$KOPAH_S3CFG"
  if [[ "${KOPAH_REMOVE_LOCAL_BRANCH_OUTPUT:-0}" == "1" ]]; then
    rm -rf "${HCP_STRUCTURAL_OUT:?}/${hcp_subject}"
    if [[ "${KOPAH_STAGE_BRANCHES:-0}" == "1" ]]; then rm -rf "$branch_stage_root"; fi
  fi
fi
