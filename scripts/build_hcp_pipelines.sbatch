#!/bin/bash
#SBATCH --job-name=hcp_pipelines_build
#SBATCH --account=fang
#SBATCH --partition=ckpt-all
#SBATCH --cpus-per-task=2
#SBATCH --mem=32G
#SBATCH --time=04:00:00

set -euo pipefail
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export LD_PRELOAD="${LD_PRELOAD:-}"


# ============================================================
# Configuration
# ============================================================

HCP_PIPELINES_VERSION="${HCP_PIPELINES_VERSION:-5.0.0}"

# CHANGE THIS if your lab/project uses a different shared image directory.
CONTAINER_DIR="${CONTAINER_DIR:-/gscratch/fang/resources/images}"

CONTAINER="${CONTAINER_DIR}/hcp-pipelines-${HCP_PIPELINES_VERSION}.sif"

# Override this with a lab-approved or registered QuNex/HCP source when needed:
#
#   HCP_PIPELINES_SOURCE=docker://YOUR_IMAGE:TAG sbatch scripts/build_hcp_pipelines.sbatch
#
# HCP Pipelines v5.0.0 was announced with a QuNex container distribution, but
# QuNex access may require registration. This public fallback image includes
# HCP Pipelines v5.0.0 and its companion neuroimaging tools.
HCP_PIPELINES_SOURCE="${HCP_PIPELINES_SOURCE:-docker://kytk/l4n-hcppipelines:latest}"

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

export APPTAINER_CACHEDIR="${APPTAINER_CACHEDIR:-/scr/${USER}/apptainer_cache}"
export APPTAINER_TMPDIR="${APPTAINER_TMPDIR:-/scr/${USER}/apptainer_tmp}"

mkdir -p "${APPTAINER_CACHEDIR}"
mkdir -p "${APPTAINER_TMPDIR}"


# ============================================================
# Pull/build HCP Pipelines image
# ============================================================

echo "============================================================"
echo "Building HCP Pipelines ${HCP_PIPELINES_VERSION} Apptainer image"
echo "Source: ${HCP_PIPELINES_SOURCE}"
echo "Output: ${CONTAINER}"
echo "============================================================"

apptainer pull \
    --force \
    "${CONTAINER}" \
    "${HCP_PIPELINES_SOURCE}"


# ============================================================
# Verify
# ============================================================

echo
echo "Checking HCP Pipelines version and key tools..."

apptainer exec \
    "${CONTAINER}" \
    bash -lc 'set -e; echo "PATH=${PATH}"; for cmd in wb_command msm flirt recon-all; do if command -v "${cmd}" >/dev/null 2>&1; then echo "${cmd}: $(command -v "${cmd}")"; else echo "WARNING: ${cmd} not found on PATH"; fi; done; if command -v show_version >/dev/null 2>&1; then show_version || true; elif [[ -x /pipeline_tools/HCPpipelines/show_version ]]; then /pipeline_tools/HCPpipelines/show_version || true; else find / -path "*/HCPpipelines/show_version" -type f -executable -print -quit 2>/dev/null | xargs -r -I{} sh -c "{} || true"; fi'


# ============================================================
# Record container checksum and metadata
# ============================================================

echo
echo "Computing SHA256..."

sha256sum "${CONTAINER}" \
    > "${CONTAINER}.sha256"

apptainer inspect "${CONTAINER}" \
    > "${CONTAINER}.inspect.txt"


echo
echo "============================================================"
echo "DONE"
echo "Container:"
echo "${CONTAINER}"
echo
echo "Set this in config/mri_preproc.env:"
echo "HCP_IMAGE=\"${CONTAINER}\""
echo
echo "Checksum:"
cat "${CONTAINER}.sha256"
echo "============================================================"
