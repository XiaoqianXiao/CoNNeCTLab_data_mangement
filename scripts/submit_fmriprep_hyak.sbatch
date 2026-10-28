#!/usr/bin/env bash
#SBATCH --job-name=r01-fmriprep
#SBATCH --account=fang
#SBATCH --partition=ckpt-all
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=48:00:00

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  sbatch [SLURM_OPTIONS] scripts/submit_fmriprep_hyak.sbatch CONFIG_ENV [SUBJECT_LIST]

Examples:
  sbatch scripts/submit_fmriprep_hyak.sbatch config/mri_preproc.env
  sbatch --array=0-9%4 scripts/submit_fmriprep_hyak.sbatch config/mri_preproc.env logs/subjects.txt

This submits the canonical fMRIPrep worker to Hyak.
When run as a SLURM array with SUBJECT_LIST, each array task runs one subject.
Use scripts/submit_fmriprep_onestep_array_hyak.sh for cohort-wide parallel runs.
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

mkdir -p "$LOG_DIR" "$WORK_DIR" "$FMRIPREP_OUT" "$FS_SUBJECTS_DIR"

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
  export FMRIPREP_SINGLE_SUBJECT="$subject"
fi

if [[ "${FMRIPREP_STAGE_FROM_KOPAH:-0}" == "1" ]]; then
  if [[ -z "${FMRIPREP_SINGLE_SUBJECT:-}" ]]; then
    echo "ERROR: Kopah staging requires one subject per Slurm task." >&2
    exit 2
  fi
  for required_var in KOPAH_S3CFG KOPAH_BIDS_URI FMRIPREP_STAGE_ROOT; do
    if [[ -z "${!required_var:-}" ]]; then
      echo "ERROR: $required_var is required when FMRIPREP_STAGE_FROM_KOPAH=1." >&2
      exit 2
    fi
  done

  stage_bids_dir="${FMRIPREP_STAGE_ROOT}/${SLURM_JOB_ID:-manual}/bids"
  staged_subject_dir="${stage_bids_dir}/${FMRIPREP_SINGLE_SUBJECT}"
  if [[ -e "$staged_subject_dir" ]]; then
    echo "ERROR: staging destination already exists: $staged_subject_dir" >&2
    exit 2
  fi

  "${REPO_DIR}/scripts/sync_kopah.sh" pull \
    "${KOPAH_BIDS_URI%/}/${FMRIPREP_SINGLE_SUBJECT}" \
    "$staged_subject_dir" \
    --s3cfg "$KOPAH_S3CFG"

  # fMRIPrep requires the dataset-level BIDS description in addition to the
  # staged subject directory.
  mkdir -p "$stage_bids_dir"
  s3cmd --config="$KOPAH_S3CFG" get \
    "${KOPAH_BIDS_URI%/}/dataset_description.json" \
    "${stage_bids_dir}/dataset_description.json"
  export FMRIPREP_STAGED_BIDS_DIR="$stage_bids_dir"
fi

export OMP_NUM_THREADS="${OMP_NTHREADS}"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${OMP_NTHREADS}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export LD_PRELOAD="${LD_PRELOAD:-}"

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
echo "SLURM_CPUS_PER_TASK=${SLURM_CPUS_PER_TASK:-NA}"
echo "CONFIG_ENV=$CONFIG_ENV"
echo "FMRIPREP_SINGLE_SUBJECT=${FMRIPREP_SINGLE_SUBJECT:-}"

"${REPO_DIR}/scripts/run_fmriprep.sh" "$CONFIG_ENV"

if [[ "${FMRIPREP_STAGE_FROM_KOPAH:-0}" == "1" ]]; then
  echo "Removing per-job staged BIDS input: ${stage_bids_dir}"
  rm -rf "$stage_bids_dir"
fi
