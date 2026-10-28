#!/bin/bash

# Define where your dicoms are
DICOM_ROOT=/gscratch/scrubbed/fanglab/xiaoqian/IFOCUS/sourcedata/dicom
LOG_DIR=/gscratch/scrubbed/fanglab/xiaoqian/IFOCUS/logs/heudiconv
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEUDICONV_TIME="${HEUDICONV_TIME:-04:00:00}"
HEUDICONV_ARRAY_MAX_CONCURRENT="${HEUDICONV_ARRAY_MAX_CONCURRENT:-10}"

# Create the Slurm log directory.
mkdir -p "${LOG_DIR}"

# Ensure the NIfTI destination exists before array jobs begin.
mkdir -p /gscratch/scrubbed/fanglab/xiaoqian/IFOCUS/sourcedata/nii

# Count number of directories in DICOM_ROOT
# We subtract 1 because array indices start at 0
NUM_SUBJ=$(ls -d "${DICOM_ROOT}"/* | wc -l)
ARRAY_LIMIT=$((NUM_SUBJ - 1))

echo "Submitting job array for indices 0 to ${ARRAY_LIMIT} (maximum ${HEUDICONV_ARRAY_MAX_CONCURRENT} concurrent tasks; ${HEUDICONV_TIME} per task)..."

# Throttle concurrent conversions to avoid saturating shared storage.
sbatch --time="${HEUDICONV_TIME}" --array=0-${ARRAY_LIMIT}%${HEUDICONV_ARRAY_MAX_CONCURRENT} "${SCRIPT_DIR}/heudiconv_job.sbatch"
