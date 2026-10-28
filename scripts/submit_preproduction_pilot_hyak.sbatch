#!/usr/bin/env bash
#SBATCH --job-name=r01-fmriprep-pilot
#SBATCH --account=fang
#SBATCH --partition=ckpt-all
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=48:00:00
#SBATCH --output=/gscratch/scrubbed/fanglab/xiaoqian/IFOCUS/logs/slurm/fmriprep/fmriprep_pilot_%j.out
#SBATCH --error=/gscratch/scrubbed/fanglab/xiaoqian/IFOCUS/logs/slurm/fmriprep/fmriprep_pilot_%j.err

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  sbatch scripts/submit_preproduction_pilot_hyak.sbatch CONFIG_ENV

Runs the full pre-production pilot on Hyak:
1. BIDS validation
2. AP/PA SDC metadata audit
3. canonical fMRIPrep pilot run
4. expected-output check
5. release manifest
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  exit 0
fi

CONFIG_ENV="$1"
REPO_DIR="${SLURM_SUBMIT_DIR:-$(pwd)}"
cd "$REPO_DIR"

if [[ "$CONFIG_ENV" != /* ]]; then
  CONFIG_ENV="${REPO_DIR}/${CONFIG_ENV}"
fi

# shellcheck source=/dev/null
source "$CONFIG_ENV"

mkdir -p "$LOG_DIR" "$WORK_DIR" "$FMRIPREP_OUT" "$FS_SUBJECTS_DIR" "$PROVENANCE_DIR"

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
echo "SLURM_CPUS_PER_TASK=${SLURM_CPUS_PER_TASK:-NA}"
echo "CONFIG_ENV=$CONFIG_ENV"

"${REPO_DIR}/scripts/run_preproduction_pilot.sh" "$CONFIG_ENV"
