#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ENV="${1:-${SCRIPT_DIR}/../config/CoNNeCTLab_data_management.env}"
if [[ "$CONFIG_ENV" != /* ]]; then
  CONFIG_ENV="$(cd "${SCRIPT_DIR}/.." && pwd)/${CONFIG_ENV}"
fi
# shellcheck source=/dev/null
source "$CONFIG_ENV"

DICOM_ROOT="${SCRUBBED_PROJECT_DIR:?ERROR: SCRUBBED_PROJECT_DIR must be set in the config}/sourcedata/dicom"
LOG_DIR="${LOG_ROOT:?ERROR: LOG_ROOT must be set in the config}/heudiconv"
HEUDICONV_TIME="${HEUDICONV_TIME:-04:00:00}"
HEUDICONV_ARRAY_MAX_CONCURRENT="${HEUDICONV_ARRAY_MAX_CONCURRENT:-10}"

# Create the Slurm log directory.
mkdir -p "${LOG_DIR}"

# Ensure the NIfTI destination exists before array jobs begin.
mkdir -p "${SCRUBBED_PROJECT_DIR}/sourcedata/nii"

# Count number of directories in DICOM_ROOT
# We subtract 1 because array indices start at 0
NUM_SUBJ=$(ls -d "${DICOM_ROOT}"/* | wc -l)
ARRAY_LIMIT=$((NUM_SUBJ - 1))

echo "Submitting job array for indices 0 to ${ARRAY_LIMIT} (maximum ${HEUDICONV_ARRAY_MAX_CONCURRENT} concurrent tasks; ${HEUDICONV_TIME} per task)..."

# Throttle concurrent conversions to avoid saturating shared storage.
sbatch --time="${HEUDICONV_TIME}" --array=0-${ARRAY_LIMIT}%${HEUDICONV_ARRAY_MAX_CONCURRENT} \
  --output="${LOG_DIR}/%x_%A_%a.out" \
  --error="${LOG_DIR}/%x_%A_%a.err" \
  "${SCRIPT_DIR}/heudiconv_job.sbatch" "$CONFIG_ENV"
