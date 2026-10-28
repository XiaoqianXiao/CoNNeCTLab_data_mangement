#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_hcp_functional.sh CONFIG_ENV

Runs HCP functional preprocessing for surface-based analysis:
  GenericfMRIVolume -> GenericfMRISurface -> multi-run ICA-FIX

Prerequisite:
  scripts/run_hcp_structural.sh must have created SUBJECT/MNINonLinear.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  exit 0
fi

CONFIG_ENV="$1"
# shellcheck source=/dev/null
source "$CONFIG_ENV"

HCP_STRUCTURAL_OUT="${HCP_STRUCTURAL_OUT:-${DERIVATIVES_DIR}/hcp}"
HCP_FUNCTIONAL_WORK="${HCP_FUNCTIONAL_WORK:-${WORK_ROOT:-${SCRUBBED_PROJECT_DIR}/scratch}/hcp-functional}"
HCP_FUNCTIONAL_PARTICIPANT_LABELS="${HCP_FUNCTIONAL_PARTICIPANT_LABELS:-${PARTICIPANT_LABELS:-}}"
HCP_FUNCTIONAL_RUN_GLOB="${HCP_FUNCTIONAL_RUN_GLOB:-func/*_bold.nii.gz}"
HCP_FUNCTIONAL_RUN_INCLUDE_REGEX="${HCP_FUNCTIONAL_RUN_INCLUDE_REGEX:-}"
HCP_FUNCTIONAL_RUN_EXCLUDE_REGEX="${HCP_FUNCTIONAL_RUN_EXCLUDE_REGEX:-desc-|space-|_boldref}"
HCP_FMRI_TOPUP_NEGATIVE_GLOB="${HCP_FMRI_TOPUP_NEGATIVE_GLOB:-fmap/*dir-AP*_epi.nii.gz}"
HCP_FMRI_TOPUP_POSITIVE_GLOB="${HCP_FMRI_TOPUP_POSITIVE_GLOB:-fmap/*dir-PA*_epi.nii.gz}"
HCP_FMRI_TOPUP_NEGATIVE_IMAGE="${HCP_FMRI_TOPUP_NEGATIVE_IMAGE:-}"
HCP_FMRI_TOPUP_POSITIVE_IMAGE="${HCP_FMRI_TOPUP_POSITIVE_IMAGE:-}"
HCP_FMRI_TOPUP_CONFIG="${HCP_FMRI_TOPUP_CONFIG:-}"
HCP_PROCESSING_MODE="${HCP_PROCESSING_MODE:-HCPStyleData}"
HCP_FMRI_ECHO_SPACING="${HCP_FMRI_ECHO_SPACING:-0.00058}"
HCP_FMRI_DISTORTION_CORRECTION="${HCP_FMRI_DISTORTION_CORRECTION:-NONE}"
HCP_FMRI_PROCESSING_MODE="${HCP_FMRI_PROCESSING_MODE:-}"
if [[ -z "$HCP_FMRI_PROCESSING_MODE" ]]; then
  if [[ "$HCP_FMRI_DISTORTION_CORRECTION" == "NONE" ]]; then
    HCP_FMRI_PROCESSING_MODE="LegacyStyleData"
  else
    HCP_FMRI_PROCESSING_MODE="$HCP_PROCESSING_MODE"
  fi
fi
HCP_FMRI_BIAS_CORRECTION="${HCP_FMRI_BIAS_CORRECTION:-LEGACY}"
HCP_FMRI_RESOLUTION="${HCP_FMRI_RESOLUTION:-2}"
HCP_FMRI_SMOOTHING_FWHM="${HCP_FMRI_SMOOTHING_FWHM:-2}"
HCP_FMRI_MC_TYPE="${HCP_FMRI_MC_TYPE:-MCFLIRT}"
HCP_FMRI_UNWARP_DIR_DEFAULT="${HCP_FMRI_UNWARP_DIR_DEFAULT:-NONE}"
HCP_FMRI_HIGH_PASS="${HCP_FMRI_HIGH_PASS:-0}"
HCP_FMRI_CONCAT_NAME="${HCP_FMRI_CONCAT_NAME:-fMRI_CONCAT}"
HCP_FMRI_OUTPUT_NAME="${HCP_FMRI_OUTPUT_NAME:-rfMRI_REST_CONCAT}"
HCP_FIX_MOTION_REGRESSION="${HCP_FIX_MOTION_REGRESSION:-TRUE}"
HCP_FIX_TRAINING_FILE="${HCP_FIX_TRAINING_FILE:-}"
HCP_FIX_THRESHOLD="${HCP_FIX_THRESHOLD:-10}"
HCP_FIX_DELETE_INTERMEDIATES="${HCP_FIX_DELETE_INTERMEDIATES:-FALSE}"
HCP_FIX_ENABLE_LEGACY="${HCP_FIX_ENABLE_LEGACY:-FALSE}"
HCP_FIX_CONCATENATE_ONLY="${HCP_FIX_CONCATENATE_ONLY:-FALSE}"
HCP_FIX_MATLAB_RUN_MODE="${HCP_FIX_MATLAB_RUN_MODE:-2}"
HCP_GRAYORDINATES_RES="${HCP_GRAYORDINATES_RES:-2}"
HCP_LOW_RES_MESH="${HCP_LOW_RES_MESH:-32}"
HCP_REG_NAME="${HCP_REG_NAME:-MSMSulc}"

if [[ -n "${HCP_FUNCTIONAL_SINGLE_SUBJECT:-}" ]]; then
  HCP_FUNCTIONAL_PARTICIPANT_LABELS="$HCP_FUNCTIONAL_SINGLE_SUBJECT"
  HCP_FUNCTIONAL_WORK="${HCP_FUNCTIONAL_WORK}/${HCP_FUNCTIONAL_SINGLE_SUBJECT#sub-}"
fi

required_vars=(BIDS_DIR DERIVATIVES_DIR LOG_DIR FS_LICENSE CONTAINER_RUNTIME HCP_IMAGE HCP_STRUCTURAL_OUT HCP_FUNCTIONAL_WORK)
for var_name in "${required_vars[@]}"; do
  [[ -n "${!var_name:-}" ]] || die "$var_name is not set in $CONFIG_ENV"
done

[[ -d "$BIDS_DIR" ]] || die "BIDS_DIR does not exist: $BIDS_DIR"
[[ -d "$HCP_STRUCTURAL_OUT" ]] || die "HCP_STRUCTURAL_OUT does not exist: $HCP_STRUCTURAL_OUT"
[[ -f "$FS_LICENSE" ]] || die "FS_LICENSE does not exist: $FS_LICENSE"
[[ -f "$HCP_IMAGE" ]] || die "HCP_IMAGE does not exist: $HCP_IMAGE"

mkdir -p "$HCP_FUNCTIONAL_WORK" "$LOG_DIR"

if [[ -n "$HCP_FUNCTIONAL_PARTICIPANT_LABELS" ]]; then
  # shellcheck disable=SC2206
  subjects=($HCP_FUNCTIONAL_PARTICIPANT_LABELS)
else
  mapfile -t subjects < <(find "$BIDS_DIR" -maxdepth 1 -type d -name 'sub-*' -exec basename {} \; | sort)
fi
[[ "${#subjects[@]}" -gt 0 ]] || die "no sub-* directories found in BIDS_DIR: $BIDS_DIR"

apptainer_no_mount_args=()
if [[ -n "${APPTAINER_NO_MOUNT:-bind-paths}" ]]; then
  apptainer_no_mount_args=(--no-mount "${APPTAINER_NO_MOUNT:-bind-paths}")
fi

timestamp="$(date +%Y%m%d_%H%M%S)"
log_label="$(echo "${HCP_FUNCTIONAL_PARTICIPANT_LABELS:-all_subjects}" | tr ' /' '__')"
array_label="${SLURM_ARRAY_TASK_ID:-manual}"
command_log="${LOG_DIR}/hcp_functional_command_${log_label}_${array_label}_${timestamp}.txt"
run_log="${LOG_DIR}/hcp_functional_run_${log_label}_${array_label}_${timestamp}.log"

cat > "$command_log" <<LOG
CONFIG_ENV=$CONFIG_ENV
HCP_IMAGE=$HCP_IMAGE
HCP_STRUCTURAL_OUT=$HCP_STRUCTURAL_OUT
HCP_FUNCTIONAL_WORK=$HCP_FUNCTIONAL_WORK
HCP_FUNCTIONAL_PARTICIPANT_LABELS=$HCP_FUNCTIONAL_PARTICIPANT_LABELS
HCP_FUNCTIONAL_RUN_GLOB=$HCP_FUNCTIONAL_RUN_GLOB
HCP_FUNCTIONAL_RUN_INCLUDE_REGEX=$HCP_FUNCTIONAL_RUN_INCLUDE_REGEX
HCP_FUNCTIONAL_RUN_EXCLUDE_REGEX=$HCP_FUNCTIONAL_RUN_EXCLUDE_REGEX
HCP_FMRI_TOPUP_NEGATIVE_GLOB=$HCP_FMRI_TOPUP_NEGATIVE_GLOB
HCP_FMRI_TOPUP_POSITIVE_GLOB=$HCP_FMRI_TOPUP_POSITIVE_GLOB
HCP_FMRI_DISTORTION_CORRECTION=$HCP_FMRI_DISTORTION_CORRECTION
HCP_FMRI_PROCESSING_MODE=$HCP_FMRI_PROCESSING_MODE
HCP_FMRI_CONCAT_NAME=$HCP_FMRI_CONCAT_NAME
LOG

run_container() {
  local subject="$1"
  local script='
set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 2
}

join_by_at() {
  local IFS="@"
  echo "$*"
}

derive_unwarp_dir() {
  local run_name="$1"
  case "$run_name" in
    *dir-PA*|*dir_PA*|*_PA|*PA) echo "y" ;;
    *dir-AP*|*dir_AP*|*_AP|*AP) echo "y-" ;;
    *dir-RL*|*dir_RL*|*_RL|*RL) echo "x" ;;
    *dir-LR*|*dir_LR*|*_LR|*LR) echo "x-" ;;
    *) echo "$HCP_FMRI_UNWARP_DIR_DEFAULT" ;;
  esac
}

first_existing_file() {
  find "$@" -type f -print -quit 2>/dev/null || true
}

topup_axis_from_unwarp_dir() {
  case "$1" in
    x|x-) echo "LR" ;;
    y|y-) echo "AP" ;;
    *) echo "" ;;
  esac
}

hcp_run_name() {
  local file="$1"
  local base
  base="$(basename "$file" .nii.gz)"
  base="${base%_bold}"
  base="${base#${SUBJECT}_}"
  echo "$base" | tr "-" "_"
}

find_hcp_dir() {
  if [[ -n "${HCPPIPEDIR:-}" && -x "${HCPPIPEDIR}/fMRIVolume/GenericfMRIVolumeProcessingPipeline.sh" ]]; then
    echo "$HCPPIPEDIR"
    return 0
  fi
  for candidate in /pipeline_tools/HCPpipelines /pipeline_tools/HCPpipelines-5.0.0 /opt/HCP-Pipelines /opt/HCPpipelines /opt/HCPpipelines-5.0.0 /usr/local/HCPpipelines /HCPpipelines; do
    if [[ -x "${candidate}/fMRIVolume/GenericfMRIVolumeProcessingPipeline.sh" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  local found
  found="$(find / -path "*/fMRIVolume/GenericfMRIVolumeProcessingPipeline.sh" -type f -executable -print -quit 2>/dev/null || true)"
  [[ -n "$found" ]] || return 1
  dirname "$(dirname "$found")"
}

SUBJECT="${HCP_SUBJECT}"
SESSION="${SUBJECT#sub-}"
STUDY_FOLDER="/hcp"

export HCPPIPEDIR
HCPPIPEDIR="$(find_hcp_dir)" || die "could not discover HCPPIPEDIR in container"
export HCPPIPEDIR_Global="${HCPPIPEDIR}/global/scripts"
export HCPPIPEDIR_Config="${HCPPIPEDIR}/global/config"
export HCPPIPEDIR_Templates="${HCPPIPEDIR}/global/templates"
export MSMCONFIGDIR="${HCPPIPEDIR}/MSMConfig"
export SUBJECTS_DIR="${STUDY_FOLDER}/${SESSION}/T1w"
export FS_LICENSE="/opt/freesurfer/license.txt"

[[ -d "${STUDY_FOLDER}/${SESSION}/MNINonLinear" ]] || die "missing HCP structural output: ${STUDY_FOLDER}/${SESSION}/MNINonLinear"

mapfile -t bold_files < <(
  find "/data/${SUBJECT}" -path "*/${HCP_FUNCTIONAL_RUN_GLOB}" -type f | sort
)
if [[ -n "$HCP_FUNCTIONAL_RUN_INCLUDE_REGEX" ]]; then
  mapfile -t bold_files < <(printf "%s\n" "${bold_files[@]}" | grep -E "$HCP_FUNCTIONAL_RUN_INCLUDE_REGEX" || true)
fi
if [[ -n "$HCP_FUNCTIONAL_RUN_EXCLUDE_REGEX" && "${#bold_files[@]}" -gt 0 ]]; then
  mapfile -t bold_files < <(printf "%s\n" "${bold_files[@]}" | grep -Ev "$HCP_FUNCTIONAL_RUN_EXCLUDE_REGEX" || true)
fi
[[ "${#bold_files[@]}" -gt 0 ]] || die "no BOLD runs found for ${SUBJECT} with HCP_FUNCTIONAL_RUN_GLOB=${HCP_FUNCTIONAL_RUN_GLOB}"

topup_neg="NONE"
topup_pos="NONE"
topup_config="NONE"
if [[ "$HCP_FMRI_DISTORTION_CORRECTION" == "TOPUP" ]]; then
  if [[ -n "$HCP_FMRI_TOPUP_NEGATIVE_IMAGE" ]]; then
    topup_neg="$HCP_FMRI_TOPUP_NEGATIVE_IMAGE"
  else
    topup_neg="$(first_existing_file "/data/${SUBJECT}" -path "*/${HCP_FMRI_TOPUP_NEGATIVE_GLOB}")"
  fi
  if [[ -n "$HCP_FMRI_TOPUP_POSITIVE_IMAGE" ]]; then
    topup_pos="$HCP_FMRI_TOPUP_POSITIVE_IMAGE"
  else
    topup_pos="$(first_existing_file "/data/${SUBJECT}" -path "*/${HCP_FMRI_TOPUP_POSITIVE_GLOB}")"
  fi
  [[ -n "$topup_neg" && -f "$topup_neg" ]] || die "TOPUP requested but no negative phase-encode SE-EPI found; set HCP_FMRI_TOPUP_NEGATIVE_GLOB or HCP_FMRI_TOPUP_NEGATIVE_IMAGE"
  [[ -n "$topup_pos" && -f "$topup_pos" ]] || die "TOPUP requested but no positive phase-encode SE-EPI found; set HCP_FMRI_TOPUP_POSITIVE_GLOB or HCP_FMRI_TOPUP_POSITIVE_IMAGE"
  if [[ -n "$HCP_FMRI_TOPUP_CONFIG" ]]; then
    topup_config="$HCP_FMRI_TOPUP_CONFIG"
  else
    topup_axis="$(topup_axis_from_unwarp_dir "$HCP_FMRI_UNWARP_DIR_DEFAULT")"
    case "$topup_axis" in
      LR) topup_config="${HCPPIPEDIR_Config}/b02b0.cnf" ;;
      AP) topup_config="${HCPPIPEDIR_Config}/b02b0.cnf" ;;
      *) topup_config="${HCPPIPEDIR_Config}/b02b0.cnf" ;;
    esac
  fi
  [[ -f "$topup_config" ]] || die "TOPUP config does not exist: $topup_config"
  echo "TOPUP negative SE-EPI: ${topup_neg}"
  echo "TOPUP positive SE-EPI: ${topup_pos}"
  echo "TOPUP config: ${topup_config}"
fi

fmri_names=()
for bold in "${bold_files[@]}"; do
  fmri_name="$(hcp_run_name "$bold")"
  fmri_names+=("$fmri_name")
  sbref="${bold%_bold.nii.gz}_sbref.nii.gz"
  if [[ ! -f "$sbref" ]]; then
    sbref="NONE"
  fi

  unwarp_dir="$(derive_unwarp_dir "$fmri_name")"
  if [[ "$HCP_FMRI_DISTORTION_CORRECTION" != "NONE" && "$unwarp_dir" == "NONE" ]]; then
    die "could not derive unwarp direction for ${bold}; set HCP_FMRI_UNWARP_DIR_DEFAULT or encode dir-AP/PA/LR/RL"
  fi

  echo "Running HCP fMRIVolume for ${SUBJECT}: ${fmri_name}"
  "${HCPPIPEDIR}/fMRIVolume/GenericfMRIVolumeProcessingPipeline.sh" \
    --path="${STUDY_FOLDER}" \
    --subject="${SESSION}" \
    --fmriname="${fmri_name}" \
    --fmritcs="${bold}" \
    --fmriscout="${sbref}" \
    --SEPhaseNeg="${topup_neg}" \
    --SEPhasePos="${topup_pos}" \
    --fmapmag="NONE" \
    --fmapphase="NONE" \
    --fmapcombined="NONE" \
    --echospacing="${HCP_FMRI_ECHO_SPACING}" \
    --echodiff="NONE" \
    --unwarpdir="${unwarp_dir}" \
    --fmrires="${HCP_FMRI_RESOLUTION}" \
    --dcmethod="${HCP_FMRI_DISTORTION_CORRECTION}" \
    --gdcoeffs="NONE" \
    --topupconfig="${topup_config}" \
    --biascorrection="${HCP_FMRI_BIAS_CORRECTION}" \
    --mctype="${HCP_FMRI_MC_TYPE}" \
    --processing-mode="${HCP_FMRI_PROCESSING_MODE}"

  echo "Running HCP fMRISurface for ${SUBJECT}: ${fmri_name}"
  "${HCPPIPEDIR}/fMRISurface/GenericfMRISurfaceProcessingPipeline.sh" \
    --path="${STUDY_FOLDER}" \
    --subject="${SESSION}" \
    --fmriname="${fmri_name}" \
    --lowresmesh="${HCP_LOW_RES_MESH}" \
    --fmrires="${HCP_FMRI_RESOLUTION}" \
    --smoothingFWHM="${HCP_FMRI_SMOOTHING_FWHM}" \
    --grayordinatesres="${HCP_GRAYORDINATES_RES}" \
    --regname="${HCP_REG_NAME}"
done

fmri_list="$(join_by_at "${fmri_names[@]}")"
fix_cmd=(
  "${HCPPIPEDIR}/ICAFIX/hcp_fix_multi_run"
  --fmri-names="${fmri_list}"
  --high-pass="${HCP_FMRI_HIGH_PASS}"
  --concat-fmri-name="${HCP_FMRI_CONCAT_NAME}"
  --motion-regression="${HCP_FIX_MOTION_REGRESSION}"
  --delete-intermediates="${HCP_FIX_DELETE_INTERMEDIATES}"
  --enable-legacy-fix="${HCP_FIX_ENABLE_LEGACY}"
  --fix-threshold="${HCP_FIX_THRESHOLD}"
  --concatenate-only="${HCP_FIX_CONCATENATE_ONLY}"
  --matlab-run-mode="${HCP_FIX_MATLAB_RUN_MODE}"
  --processing-mode="${HCP_FMRI_PROCESSING_MODE}"
)
if [[ -n "$HCP_FIX_TRAINING_FILE" ]]; then
  fix_cmd+=(--training-file="$HCP_FIX_TRAINING_FILE")
fi

echo "Running HCP multi-run FIX for ${SUBJECT}: ${fmri_list}"
(
  cd "${STUDY_FOLDER}/${SESSION}/MNINonLinear/Results"
  "${fix_cmd[@]}"
)

expected="${STUDY_FOLDER}/${SESSION}/MNINonLinear/Results/${HCP_FMRI_CONCAT_NAME}/${HCP_FMRI_CONCAT_NAME}_Atlas_hp${HCP_FMRI_HIGH_PASS}_clean.dtseries.nii"
[[ -f "$expected" ]] || die "multi-run FIX did not create expected surface output: $expected"

expected_vn="${STUDY_FOLDER}/${SESSION}/MNINonLinear/Results/${HCP_FMRI_CONCAT_NAME}/${HCP_FMRI_CONCAT_NAME}_Atlas_hp${HCP_FMRI_HIGH_PASS}_clean_vn.dscalar.nii"
[[ -f "$expected_vn" ]] || die "multi-run FIX did not create expected surface scalar output: $expected_vn"

echo "HCP functional/FIX complete for ${SUBJECT}"
'

  case "$CONTAINER_RUNTIME" in
    docker)
      docker run --rm \
        -e HCP_SUBJECT="$subject" \
        -e HCP_FUNCTIONAL_RUN_GLOB="$HCP_FUNCTIONAL_RUN_GLOB" \
        -e HCP_FUNCTIONAL_RUN_INCLUDE_REGEX="$HCP_FUNCTIONAL_RUN_INCLUDE_REGEX" \
        -e HCP_FUNCTIONAL_RUN_EXCLUDE_REGEX="$HCP_FUNCTIONAL_RUN_EXCLUDE_REGEX" \
        -e HCP_FMRI_TOPUP_NEGATIVE_GLOB="$HCP_FMRI_TOPUP_NEGATIVE_GLOB" \
        -e HCP_FMRI_TOPUP_POSITIVE_GLOB="$HCP_FMRI_TOPUP_POSITIVE_GLOB" \
        -e HCP_FMRI_TOPUP_NEGATIVE_IMAGE="$HCP_FMRI_TOPUP_NEGATIVE_IMAGE" \
        -e HCP_FMRI_TOPUP_POSITIVE_IMAGE="$HCP_FMRI_TOPUP_POSITIVE_IMAGE" \
        -e HCP_FMRI_TOPUP_CONFIG="$HCP_FMRI_TOPUP_CONFIG" \
        -e HCP_FMRI_ECHO_SPACING="$HCP_FMRI_ECHO_SPACING" \
        -e HCP_FMRI_DISTORTION_CORRECTION="$HCP_FMRI_DISTORTION_CORRECTION" \
        -e HCP_FMRI_PROCESSING_MODE="$HCP_FMRI_PROCESSING_MODE" \
        -e HCP_FMRI_BIAS_CORRECTION="$HCP_FMRI_BIAS_CORRECTION" \
        -e HCP_FMRI_RESOLUTION="$HCP_FMRI_RESOLUTION" \
        -e HCP_FMRI_SMOOTHING_FWHM="$HCP_FMRI_SMOOTHING_FWHM" \
        -e HCP_FMRI_MC_TYPE="$HCP_FMRI_MC_TYPE" \
        -e HCP_FMRI_UNWARP_DIR_DEFAULT="$HCP_FMRI_UNWARP_DIR_DEFAULT" \
        -e HCP_FMRI_HIGH_PASS="$HCP_FMRI_HIGH_PASS" \
        -e HCP_FMRI_CONCAT_NAME="$HCP_FMRI_CONCAT_NAME" \
        -e HCP_FMRI_OUTPUT_NAME="$HCP_FMRI_OUTPUT_NAME" \
        -e HCP_FIX_MOTION_REGRESSION="$HCP_FIX_MOTION_REGRESSION" \
        -e HCP_FIX_TRAINING_FILE="$HCP_FIX_TRAINING_FILE" \
        -e HCP_FIX_THRESHOLD="$HCP_FIX_THRESHOLD" \
        -e HCP_FIX_DELETE_INTERMEDIATES="$HCP_FIX_DELETE_INTERMEDIATES" \
        -e HCP_FIX_ENABLE_LEGACY="$HCP_FIX_ENABLE_LEGACY" \
        -e HCP_FIX_CONCATENATE_ONLY="$HCP_FIX_CONCATENATE_ONLY" \
        -e HCP_FIX_MATLAB_RUN_MODE="$HCP_FIX_MATLAB_RUN_MODE" \
        -e HCP_GRAYORDINATES_RES="$HCP_GRAYORDINATES_RES" \
        -e HCP_LOW_RES_MESH="$HCP_LOW_RES_MESH" \
        -e HCP_REG_NAME="$HCP_REG_NAME" \
        -e HCP_PROCESSING_MODE="$HCP_PROCESSING_MODE" \
        -v "${BIDS_DIR}:/data:ro" \
        -v "${HCP_STRUCTURAL_OUT}:/hcp" \
        -v "${HCP_FUNCTIONAL_WORK}:/work" \
        -v "${FS_LICENSE}:/opt/freesurfer/license.txt:ro" \
        "$HCP_IMAGE" \
        bash -lc "$script"
      ;;
    apptainer)
      apptainer exec --cleanenv \
        "${apptainer_no_mount_args[@]}" \
        --env HCP_SUBJECT="$subject" \
        --env HCP_FUNCTIONAL_RUN_GLOB="$HCP_FUNCTIONAL_RUN_GLOB" \
        --env HCP_FUNCTIONAL_RUN_INCLUDE_REGEX="$HCP_FUNCTIONAL_RUN_INCLUDE_REGEX" \
        --env HCP_FUNCTIONAL_RUN_EXCLUDE_REGEX="$HCP_FUNCTIONAL_RUN_EXCLUDE_REGEX" \
        --env HCP_FMRI_TOPUP_NEGATIVE_GLOB="$HCP_FMRI_TOPUP_NEGATIVE_GLOB" \
        --env HCP_FMRI_TOPUP_POSITIVE_GLOB="$HCP_FMRI_TOPUP_POSITIVE_GLOB" \
        --env HCP_FMRI_TOPUP_NEGATIVE_IMAGE="$HCP_FMRI_TOPUP_NEGATIVE_IMAGE" \
        --env HCP_FMRI_TOPUP_POSITIVE_IMAGE="$HCP_FMRI_TOPUP_POSITIVE_IMAGE" \
        --env HCP_FMRI_TOPUP_CONFIG="$HCP_FMRI_TOPUP_CONFIG" \
        --env HCP_FMRI_ECHO_SPACING="$HCP_FMRI_ECHO_SPACING" \
        --env HCP_FMRI_DISTORTION_CORRECTION="$HCP_FMRI_DISTORTION_CORRECTION" \
        --env HCP_FMRI_PROCESSING_MODE="$HCP_FMRI_PROCESSING_MODE" \
        --env HCP_FMRI_BIAS_CORRECTION="$HCP_FMRI_BIAS_CORRECTION" \
        --env HCP_FMRI_RESOLUTION="$HCP_FMRI_RESOLUTION" \
        --env HCP_FMRI_SMOOTHING_FWHM="$HCP_FMRI_SMOOTHING_FWHM" \
        --env HCP_FMRI_MC_TYPE="$HCP_FMRI_MC_TYPE" \
        --env HCP_FMRI_UNWARP_DIR_DEFAULT="$HCP_FMRI_UNWARP_DIR_DEFAULT" \
        --env HCP_FMRI_HIGH_PASS="$HCP_FMRI_HIGH_PASS" \
        --env HCP_FMRI_CONCAT_NAME="$HCP_FMRI_CONCAT_NAME" \
        --env HCP_FMRI_OUTPUT_NAME="$HCP_FMRI_OUTPUT_NAME" \
        --env HCP_FIX_MOTION_REGRESSION="$HCP_FIX_MOTION_REGRESSION" \
        --env HCP_FIX_TRAINING_FILE="$HCP_FIX_TRAINING_FILE" \
        --env HCP_FIX_THRESHOLD="$HCP_FIX_THRESHOLD" \
        --env HCP_FIX_DELETE_INTERMEDIATES="$HCP_FIX_DELETE_INTERMEDIATES" \
        --env HCP_FIX_ENABLE_LEGACY="$HCP_FIX_ENABLE_LEGACY" \
        --env HCP_FIX_CONCATENATE_ONLY="$HCP_FIX_CONCATENATE_ONLY" \
        --env HCP_FIX_MATLAB_RUN_MODE="$HCP_FIX_MATLAB_RUN_MODE" \
        --env HCP_GRAYORDINATES_RES="$HCP_GRAYORDINATES_RES" \
        --env HCP_LOW_RES_MESH="$HCP_LOW_RES_MESH" \
        --env HCP_REG_NAME="$HCP_REG_NAME" \
        --env HCP_PROCESSING_MODE="$HCP_PROCESSING_MODE" \
        -B "${BIDS_DIR}:/data:ro" \
        -B "${HCP_STRUCTURAL_OUT}:/hcp" \
        -B "${HCP_FUNCTIONAL_WORK}:/work" \
        -B "${FS_LICENSE}:/opt/freesurfer/license.txt:ro" \
        "$HCP_IMAGE" \
        bash -lc "$script"
      ;;
    singularity)
      singularity exec --cleanenv \
        "${apptainer_no_mount_args[@]}" \
        --env HCP_SUBJECT="$subject" \
        --env HCP_FUNCTIONAL_RUN_GLOB="$HCP_FUNCTIONAL_RUN_GLOB" \
        --env HCP_FUNCTIONAL_RUN_INCLUDE_REGEX="$HCP_FUNCTIONAL_RUN_INCLUDE_REGEX" \
        --env HCP_FUNCTIONAL_RUN_EXCLUDE_REGEX="$HCP_FUNCTIONAL_RUN_EXCLUDE_REGEX" \
        --env HCP_FMRI_TOPUP_NEGATIVE_GLOB="$HCP_FMRI_TOPUP_NEGATIVE_GLOB" \
        --env HCP_FMRI_TOPUP_POSITIVE_GLOB="$HCP_FMRI_TOPUP_POSITIVE_GLOB" \
        --env HCP_FMRI_TOPUP_NEGATIVE_IMAGE="$HCP_FMRI_TOPUP_NEGATIVE_IMAGE" \
        --env HCP_FMRI_TOPUP_POSITIVE_IMAGE="$HCP_FMRI_TOPUP_POSITIVE_IMAGE" \
        --env HCP_FMRI_TOPUP_CONFIG="$HCP_FMRI_TOPUP_CONFIG" \
        --env HCP_FMRI_ECHO_SPACING="$HCP_FMRI_ECHO_SPACING" \
        --env HCP_FMRI_DISTORTION_CORRECTION="$HCP_FMRI_DISTORTION_CORRECTION" \
        --env HCP_FMRI_PROCESSING_MODE="$HCP_FMRI_PROCESSING_MODE" \
        --env HCP_FMRI_BIAS_CORRECTION="$HCP_FMRI_BIAS_CORRECTION" \
        --env HCP_FMRI_RESOLUTION="$HCP_FMRI_RESOLUTION" \
        --env HCP_FMRI_SMOOTHING_FWHM="$HCP_FMRI_SMOOTHING_FWHM" \
        --env HCP_FMRI_MC_TYPE="$HCP_FMRI_MC_TYPE" \
        --env HCP_FMRI_UNWARP_DIR_DEFAULT="$HCP_FMRI_UNWARP_DIR_DEFAULT" \
        --env HCP_FMRI_HIGH_PASS="$HCP_FMRI_HIGH_PASS" \
        --env HCP_FMRI_CONCAT_NAME="$HCP_FMRI_CONCAT_NAME" \
        --env HCP_FMRI_OUTPUT_NAME="$HCP_FMRI_OUTPUT_NAME" \
        --env HCP_FIX_MOTION_REGRESSION="$HCP_FIX_MOTION_REGRESSION" \
        --env HCP_FIX_TRAINING_FILE="$HCP_FIX_TRAINING_FILE" \
        --env HCP_FIX_THRESHOLD="$HCP_FIX_THRESHOLD" \
        --env HCP_FIX_DELETE_INTERMEDIATES="$HCP_FIX_DELETE_INTERMEDIATES" \
        --env HCP_FIX_ENABLE_LEGACY="$HCP_FIX_ENABLE_LEGACY" \
        --env HCP_FIX_CONCATENATE_ONLY="$HCP_FIX_CONCATENATE_ONLY" \
        --env HCP_FIX_MATLAB_RUN_MODE="$HCP_FIX_MATLAB_RUN_MODE" \
        --env HCP_GRAYORDINATES_RES="$HCP_GRAYORDINATES_RES" \
        --env HCP_LOW_RES_MESH="$HCP_LOW_RES_MESH" \
        --env HCP_REG_NAME="$HCP_REG_NAME" \
        --env HCP_PROCESSING_MODE="$HCP_PROCESSING_MODE" \
        -B "${BIDS_DIR}:/data:ro" \
        -B "${HCP_STRUCTURAL_OUT}:/hcp" \
        -B "${HCP_FUNCTIONAL_WORK}:/work" \
        -B "${FS_LICENSE}:/opt/freesurfer/license.txt:ro" \
        "$HCP_IMAGE" \
        bash -lc "$script"
      ;;
    *)
      die "Unsupported CONTAINER_RUNTIME: $CONTAINER_RUNTIME"
      ;;
  esac
}

for subject in "${subjects[@]}"; do
  subject="${subject#sub-}"
  run_container "sub-${subject}"
done 2>&1 | tee "$run_log"

echo "Command record: $command_log"
echo "Run log: $run_log"
