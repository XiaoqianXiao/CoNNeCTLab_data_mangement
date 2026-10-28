#!/bin/bash
#SBATCH --job-name=heudiconv
#SBATCH --partition=ckpt-all
#SBATCH --account=fang
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=12G
#SBATCH --time=04:00:00

set -euo pipefail

# --- Configuration ---
HEUDICONV_SIF=/gscratch/fang/resources/images/heudiconv.sif
HEURISTIC=/gscratch/scrubbed/fanglab/xiaoqian/repo/R01/scripts/heuristic_reproin_like.py
CONFIG_ENV="${1:?Usage: heudiconv_job.sbatch CONFIG_ENV}"
if [[ "$CONFIG_ENV" != /* ]]; then
  CONFIG_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/${CONFIG_ENV}"
fi
# shellcheck source=/dev/null
source "$CONFIG_ENV"

B0_LINKER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/link_bold_to_fieldmaps.py"

DICOM_ROOT="${SCRUBBED_PROJECT_DIR:?ERROR: SCRUBBED_PROJECT_DIR must be set in the config}/sourcedata/dicom"
BIDS_ROOT="${SCRUBBED_PROJECT_DIR}/sourcedata/nii"

module load apptainer 2>/dev/null || true

# --- 1. Identify subject ---
# Manual example:
# sbatch --export=ALL,TARGET_SUB=139,TARGET_SES=T12 heudiconv_job.sbatch

# Select subject.
if [[ -n "${TARGET_SUB:-}" ]]; then
    SUBJ="${TARGET_SUB#sub-}"
else
    mapfile -t SUBJECTS < <(
        find "${DICOM_ROOT}" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -printf '%f\n' |
            sort -V
    )

    TASK_ID="${SLURM_ARRAY_TASK_ID:?Set TARGET_SUB or SLURM_ARRAY_TASK_ID}"

    if ((TASK_ID < 0 || TASK_ID >= ${#SUBJECTS[@]})); then
        echo "Error: SLURM_ARRAY_TASK_ID ${TASK_ID} is outside the subject list." >&2
        exit 1
    fi

    SUBJ="${SUBJECTS[$TASK_ID]#sub-}"
fi

SOURCE_SUBJ_PATH="${DICOM_ROOT}/${SUBJ}"

if [[ ! -d "${SOURCE_SUBJ_PATH}" ]]; then
    echo "Error: subject directory not found: ${SOURCE_SUBJ_PATH}" >&2
    exit 1
fi

# Stage the full subject tree to compute-node scratch once. The source exports
# may contain symlinks, so dereference them while copying to ensure conversion
# reads DICOM bytes locally rather than back through the shared filesystem.
LOCAL_ROOT="${SLURM_TMPDIR:-/tmp}/heudiconv_${SLURM_JOB_ID:-manual}_${SUBJ}"
LOCAL_DICOM_ROOT="${LOCAL_ROOT}/dicom"
HEUDICONV_WORK_ROOT="${LOCAL_ROOT}/work"

cleanup_local_stage() {
    rm -rf "${LOCAL_ROOT}"
}
trap cleanup_local_stage EXIT

mkdir -p "${LOCAL_DICOM_ROOT}"
SOURCE_KB="$(du -skL "${SOURCE_SUBJ_PATH}" | awk '{print $1}')"
AVAILABLE_KB="$(df -Pk "${LOCAL_ROOT}" | awk 'NR == 2 {print $4}')"

if [[ -z "${SOURCE_KB}" || -z "${AVAILABLE_KB}" ]]; then
    echo "ERROR: unable to determine DICOM source size or local scratch capacity." >&2
    exit 1
fi

# Reserve 20% plus 4 GiB for temporary conversion work and filesystem overhead.
REQUIRED_KB=$((SOURCE_KB + SOURCE_KB / 5 + 4 * 1024 * 1024))

if ((AVAILABLE_KB < REQUIRED_KB)); then
    echo "ERROR: insufficient local scratch for subject ${SUBJ}." >&2
    echo "Required: ${REQUIRED_KB} KiB; available: ${AVAILABLE_KB} KiB." >&2
    exit 1
fi

echo "Staging ${SOURCE_SUBJ_PATH} to ${LOCAL_DICOM_ROOT}/${SUBJ}..."
STAGING_START_SECONDS=${SECONDS}
rsync -aL -- "${SOURCE_SUBJ_PATH}/" "${LOCAL_DICOM_ROOT}/${SUBJ}/"
echo "DICOM staging completed in $((SECONDS - STAGING_START_SECONDS)) seconds."

SUBJ_PATH="${LOCAL_DICOM_ROOT}/${SUBJ}"
mkdir -p "${HEUDICONV_WORK_ROOT}"

# Process source sessions such as:
# dicom/127/ses-T6
for SES_PATH in "${SUBJ_PATH}"/ses-*; do
    [[ -d "${SES_PATH}" ]] || continue

    SES_FOLDER="$(basename "${SES_PATH}")"  # ses-T6
    SES="${SES_FOLDER#ses-}"                # T6

    if [[ -n "${TARGET_SES:-}" ]]; then
        TARGET_SES_CLEAN="${TARGET_SES#ses-}"
        [[ "${SES}" == "${TARGET_SES_CLEAN}" ]] || continue
    fi

    echo "------------------------------------------------"
    echo "Subject        : ${SUBJ}"
    echo "Source session : ${SES_PATH}"
    echo "Session arg    : ${SES}"
    echo "Expected output: ${BIDS_ROOT}/sub-${SUBJ}/ses-${SES}"
    echo "------------------------------------------------"

    SESSION_START_SECONDS=${SECONDS}

    TMP_ROOT="${SLURM_TMPDIR:-/tmp}/heudiconv_${SLURM_JOB_ID:-manual}_${SUBJ}_${SES}"
    TMP_SES="${TMP_ROOT}/${SUBJ}/ses-${SES}"

    rm -rf "${TMP_ROOT}"
    mkdir -p "${TMP_SES}"

    FILE_COUNT=0
    SELECTED_SERIES_COUNT=0

    # Select inputs by their acquisition-directory name.  The DICOM headers
    # do not reliably preserve the RMS label, but this source layout does.
    # Keep the MEMPRvNav RMS reconstruction, functional runs, and AP/PA EPI
    # fieldmaps; omit raw echoes, scouts, setters, and physiology logs.
    for SERIES_PATH in "${SES_PATH}"/*; do
        [[ -d "${SERIES_PATH}" ]] || continue
        SERIES_NAME="$(basename "${SERIES_PATH}")"

        case "${SERIES_NAME}" in
            anat-T1w_acq-MEMPRvNav_RMS|\
            fmap-epi_acq-opphase_dir-AP|\
            fmap-epi_acq-opphase_dir-PA)
                ;;
            func-bold_task-*)
                [[ "${SERIES_NAME}" != *_PhysioLog ]] || continue
                ;;
            *)
                echo "Skipping source series: ${SERIES_NAME}"
                continue
                ;;
        esac

        SERIES_FILE_COUNT=0
        while IFS= read -r -d '' DICOM_FILE; do
            FILE_COUNT=$((FILE_COUNT + 1))
            SERIES_FILE_COUNT=$((SERIES_FILE_COUNT + 1))
            STAGED_NAME="$(printf '%06d.dcm' "${FILE_COUNT}")"
            CONTAINER_DICOM="/dicom/${DICOM_FILE#${LOCAL_DICOM_ROOT}/}"

            ln -s "${CONTAINER_DICOM}" "${TMP_SES}/${STAGED_NAME}"
        done < <(
            # The acquisition exports may be symlinked into sourcedata. Follow
            # only valid links, then recurse into their DICOM directories and
            # retain regular .dcm/.dicom files.
            find -L "${SERIES_PATH}" \
                -type f \
                \( -iname '*.dcm' -o -iname '*.dicom' \) \
                -print0 |
                sort -z
        )

        if ((SERIES_FILE_COUNT == 0)); then
            echo "ERROR: selected source series has no .dcm or .dicom file: ${SERIES_PATH}" >&2
            rm -rf "${TMP_ROOT}"
            exit 1
        fi

        SELECTED_SERIES_COUNT=$((SELECTED_SERIES_COUNT + 1))
        echo "Selected source series: ${SERIES_NAME} (${SERIES_FILE_COUNT} DICOM file(s))"
    done

    if ((FILE_COUNT == 0)); then
        echo "ERROR: no selected DICOM files found under ${SES_PATH}." >&2
        rm -rf "${TMP_ROOT}"
        exit 1
    fi

    echo "Selected series: ${SELECTED_SERIES_COUNT}"
    echo "DICOM files    : ${FILE_COUNT}"

    CONVERSION_START_SECONDS=${SECONDS}
    apptainer exec \
        -B "${LOCAL_DICOM_ROOT}:/dicom:ro" \
        -B "${TMP_ROOT}:/heudiconv_input:ro" \
        -B "${BIDS_ROOT}:/bids" \
        -B "${HEUDICONV_WORK_ROOT}:/heudiconv_work" \
        -B "${HEURISTIC}:/heuristic.py:ro" \
        "${HEUDICONV_SIF}" \
        heudiconv \
            -d '/heudiconv_input/{subject}/ses-{session}/*' \
            -s "${SUBJ}" \
            -ss "${SES}" \
            -f /heuristic.py \
            -c dcm2niix \
            -b \
            -o /heudiconv_work \
            -a /bids \
            --overwrite
    echo "NIfTI conversion completed in $((SECONDS - CONVERSION_START_SECONDS)) seconds."

    # dcm2niix cannot infer this study's fieldmap-to-BOLD association. Add the
    # validated per-session B0FieldIdentifier/B0FieldSource mapping now, while
    # the subject/session conversion context is explicit.
    apptainer exec \
        -B "${BIDS_ROOT}:/bids" \
        -B "${B0_LINKER}:/link_bold_to_fieldmaps.py:ro" \
        "${HEUDICONV_SIF}" \
        python3 /link_bold_to_fieldmaps.py /bids \
            --participant-label "${SUBJ}" \
            --session-label "${SES}"
    echo "Session ${SES} completed in $((SECONDS - SESSION_START_SECONDS)) seconds."
    rm -rf "${TMP_ROOT}"
done
