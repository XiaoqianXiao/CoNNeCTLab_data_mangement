#!/bin/bash
#SBATCH --job-name=fmriprep_build
#SBATCH --account=fang
#SBATCH --partition=ckpt-all
#SBATCH --cpus-per-task=2
#SBATCH --mem=16G
#SBATCH --time=02:00:00

set -euo pipefail


# ============================================================
# Configuration
# ============================================================

FMRIPREP_VERSION="25.2.5"

# CHANGE THIS to your lab/project container directory
CONTAINER_DIR="/gscratch/fang/resources/images"

CONTAINER="${CONTAINER_DIR}/fmriprep-${FMRIPREP_VERSION}.sif"

mkdir -p "${CONTAINER_DIR}"


# ============================================================
# Load Apptainer
# ============================================================

module purge
module load apptainer

echo "Apptainer:"
apptainer --version


# ============================================================
# Use node-local storage for Apptainer cache/temp
# ============================================================

export APPTAINER_CACHEDIR="/scr/${USER}/apptainer_cache"
export APPTAINER_TMPDIR="/scr/${USER}/apptainer_tmp"

mkdir -p "${APPTAINER_CACHEDIR}"
mkdir -p "${APPTAINER_TMPDIR}"


# ============================================================
# Pull official fMRIPrep Docker image
# ============================================================

echo "============================================================"
echo "Building fMRIPrep ${FMRIPREP_VERSION} Apptainer image"
echo "Source: docker://nipreps/fmriprep:${FMRIPREP_VERSION}"
echo "Output: ${CONTAINER}"
echo "============================================================"

apptainer pull \
    "${CONTAINER}" \
    "docker://nipreps/fmriprep:${FMRIPREP_VERSION}"


# ============================================================
# Verify
# ============================================================

echo
echo "Checking fMRIPrep version..."

apptainer run \
    "${CONTAINER}" \
    --version


# ============================================================
# Record container checksum
# ============================================================

echo
echo "Computing SHA256..."

sha256sum "${CONTAINER}" \
    > "${CONTAINER}.sha256"


# Record Apptainer metadata
apptainer inspect "${CONTAINER}" \
    > "${CONTAINER}.inspect.txt"


echo
echo "============================================================"
echo "DONE"
echo "Container:"
echo "${CONTAINER}"
echo
echo "Checksum:"
cat "${CONTAINER}.sha256"
echo "============================================================"
