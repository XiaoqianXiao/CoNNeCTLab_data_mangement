#!/usr/bin/env bash
#SBATCH --job-name=flywheel_build
#SBATCH --account=fang
#SBATCH --partition=ckpt-all
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --time=01:00:00

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-${SLURM_SUBMIT_DIR:-$PWD}}"
DEFINITION_FILE="${DEFINITION_FILE:-${PROJECT_DIR}/containers/flywheel.def}"
CONTAINER_DIR="${CONTAINER_DIR:-/gscratch/fang/resources/images}"
CONTAINER="${CONTAINER:-${CONTAINER_DIR}/flywheel.sif}"
OVERWRITE="${OVERWRITE:-0}"

if [[ ! -f "${DEFINITION_FILE}" ]]; then
    echo "Error: Flywheel definition file not found: ${DEFINITION_FILE}" >&2
    exit 1
fi

if [[ "${OVERWRITE}" != "0" && "${OVERWRITE}" != "1" ]]; then
    echo "Error: OVERWRITE must be 0 or 1." >&2
    exit 1
fi

if [[ -e "${CONTAINER}" && "${OVERWRITE}" != "1" ]]; then
    cat >&2 <<MSG
Error: Refusing to replace existing container: ${CONTAINER}

Review the existing image, then rerun with OVERWRITE=1 if replacement is intended.
MSG
    exit 1
fi

mkdir -p "${CONTAINER_DIR}"

module purge
module load apptainer

echo "Apptainer: $(apptainer --version)"
echo "Definition: ${DEFINITION_FILE}"
echo "Output: ${CONTAINER}"

export APPTAINER_CACHEDIR="/scr/${USER}/apptainer_cache"
export APPTAINER_TMPDIR="/scr/${USER}/apptainer_tmp"
mkdir -p "${APPTAINER_CACHEDIR}" "${APPTAINER_TMPDIR}"

cd "${PROJECT_DIR}"
apptainer build --fakeroot "${CONTAINER}" "${DEFINITION_FILE}"

echo "Verifying Flywheel SDK..."
apptainer exec "${CONTAINER}" python3 - <<'PY'
from importlib.metadata import version

import flywheel

assert hasattr(flywheel, "Client")
print(f"flywheel-sdk {version('flywheel-sdk')}")
PY

sha256sum "${CONTAINER}" > "${CONTAINER}.sha256"
apptainer inspect "${CONTAINER}" > "${CONTAINER}.inspect.txt"

echo "Built and verified: ${CONTAINER}"
echo "Checksum: ${CONTAINER}.sha256"
