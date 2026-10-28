#!/bin/bash
#SBATCH --job-name=hippunfold_build
#SBATCH --account=fang
#SBATCH --partition=ckpt-all
#SBATCH --cpus-per-task=2
#SBATCH --mem=32G
#SBATCH --time=04:00:00
#SBATCH --output=/gscratch/scrubbed/fanglab/xiaoqian/IFOCUS/logs/build/hippunfold_%j.out
#SBATCH --error=/gscratch/scrubbed/fanglab/xiaoqian/IFOCUS/logs/build/hippunfold_%j.err

set -euo pipefail
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export LD_PRELOAD="${LD_PRELOAD:-}"


# ============================================================
# Configuration
# ============================================================

HIPPUNFOLD_VERSION="${HIPPUNFOLD_VERSION:-2.0.0}"

# CHANGE THIS if your lab/project uses a different shared image directory.
CONTAINER_DIR="${CONTAINER_DIR:-/gscratch/fang/resources/images}"

CONTAINER="${CONTAINER_DIR}/hippunfold-${HIPPUNFOLD_VERSION}.sif"

# Official HippUnfold documentation for v2.0.0 uses the dev-v2.0.0 Docker tag.
# Override this if the lab freezes a different source image:
#
#   HIPPUNFOLD_SOURCE=docker://YOUR_IMAGE:TAG sbatch scripts/build_hippunfold.sbatch
HIPPUNFOLD_SOURCE="${HIPPUNFOLD_SOURCE:-docker://khanlab/hippunfold:dev-v2.0.0}"
HIPPUNFOLD_CONTAINER_ENTRYPOINT="${HIPPUNFOLD_CONTAINER_ENTRYPOINT:-/app/entrypoint.sh}"
HIPPUNFOLD_CONTAINER_COMMAND="${HIPPUNFOLD_CONTAINER_COMMAND:-hippunfold}"

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
# Pull/build HippUnfold image
# ============================================================

echo "============================================================"
echo "Building HippUnfold ${HIPPUNFOLD_VERSION} Apptainer image"
echo "Source: ${HIPPUNFOLD_SOURCE}"
echo "Output: ${CONTAINER}"
echo "============================================================"

apptainer pull \
    --disable-cache \
    --force \
    "${CONTAINER}" \
    "${HIPPUNFOLD_SOURCE}"


# ============================================================
# Verify
# ============================================================

echo
echo "Checking HippUnfold version/help..."

if ! apptainer exec "${CONTAINER}" "${HIPPUNFOLD_CONTAINER_ENTRYPOINT}" "${HIPPUNFOLD_CONTAINER_COMMAND}" --help >/dev/null; then
    echo "ERROR: HippUnfold container command failed: ${HIPPUNFOLD_CONTAINER_ENTRYPOINT} ${HIPPUNFOLD_CONTAINER_COMMAND}" >&2
    echo "Inspecting common executable locations inside the container..." >&2
    apptainer exec "${CONTAINER}" bash -lc \
        'set +e; command -v hippunfold; python3 -m pip show hippunfold; find /usr /opt /src -maxdepth 6 \( -name hippunfold -o -name "hippunfold*" \) -print 2>/dev/null | head -n 80' >&2
    echo "If this still cannot run HippUnfold, set HIPPUNFOLD_CONTAINER_ENTRYPOINT and HIPPUNFOLD_CONTAINER_COMMAND for the image, or retry with HIPPUNFOLD_SOURCE set to a lab-approved image." >&2
    exit 1
fi


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
echo "HIPPUNFOLD_IMAGE=\"${CONTAINER}\""
echo
echo "Checksum:"
cat "${CONTAINER}.sha256"
echo "============================================================"
