#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_hcp_structural.sh CONFIG_ENV

Runs HCP Pipelines structural preprocessing for one or more subjects:
  PreFreeSurfer -> FreeSurfer -> PostFreeSurfer

This creates HCP-style SUBJECT/MNINonLinear outputs for surface-based analysis.
For Hyak arrays, submit with scripts/submit_hcp_structural_array_hyak.sh.
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
HCP_STRUCTURAL_WORK="${HCP_STRUCTURAL_WORK:-${WORK_ROOT:-${SCRUBBED_PROJECT_DIR}/scratch}/hcp-structural}"
HCP_STRUCTURAL_PARTICIPANT_LABELS="${HCP_STRUCTURAL_PARTICIPANT_LABELS:-${PARTICIPANT_LABELS:-}}"
HCP_PROCESSING_MODE="${HCP_PROCESSING_MODE:-HCPStyleData}"
HCP_GRAYORDINATES_RES="${HCP_GRAYORDINATES_RES:-2}"
HCP_HIGH_RES_MESH="${HCP_HIGH_RES_MESH:-164}"
HCP_LOW_RES_MESH="${HCP_LOW_RES_MESH:-32}"
HCP_REG_NAME="${HCP_REG_NAME:-MSMSulc}"
HCP_STRUCTURAL_QC="${HCP_STRUCTURAL_QC:-yes}"

if [[ -n "${HCP_STRUCTURAL_SINGLE_SUBJECT:-}" ]]; then
  HCP_STRUCTURAL_PARTICIPANT_LABELS="$HCP_STRUCTURAL_SINGLE_SUBJECT"
  HCP_STRUCTURAL_WORK="${HCP_STRUCTURAL_WORK}/${HCP_STRUCTURAL_SINGLE_SUBJECT#sub-}"
fi

required_vars=(BIDS_DIR DERIVATIVES_DIR LOG_DIR FS_LICENSE CONTAINER_RUNTIME HCP_IMAGE HCP_STRUCTURAL_OUT HCP_STRUCTURAL_WORK)
for var_name in "${required_vars[@]}"; do
  [[ -n "${!var_name:-}" ]] || die "$var_name is not set in $CONFIG_ENV"
done

[[ -d "$BIDS_DIR" ]] || die "BIDS_DIR does not exist: $BIDS_DIR"
[[ -f "$FS_LICENSE" ]] || die "FS_LICENSE does not exist: $FS_LICENSE"
[[ -f "$HCP_IMAGE" ]] || die "HCP_IMAGE does not exist: $HCP_IMAGE"

mkdir -p "$HCP_STRUCTURAL_OUT" "$HCP_STRUCTURAL_WORK" "$LOG_DIR"

if [[ -n "$HCP_STRUCTURAL_PARTICIPANT_LABELS" ]]; then
  # shellcheck disable=SC2206
  subjects=($HCP_STRUCTURAL_PARTICIPANT_LABELS)
else
  mapfile -t subjects < <(find "$BIDS_DIR" -maxdepth 1 -type d -name 'sub-*' -exec basename {} \; | sort)
fi
[[ "${#subjects[@]}" -gt 0 ]] || die "no sub-* directories found in BIDS_DIR: $BIDS_DIR"

apptainer_no_mount_args=()
if [[ -n "${APPTAINER_NO_MOUNT:-bind-paths}" ]]; then
  apptainer_no_mount_args=(--no-mount "${APPTAINER_NO_MOUNT:-bind-paths}")
fi

timestamp="$(date +%Y%m%d_%H%M%S)"
log_label="$(echo "${HCP_STRUCTURAL_PARTICIPANT_LABELS:-all_subjects}" | tr ' /' '__')"
array_label="${SLURM_ARRAY_TASK_ID:-manual}"
command_log="${LOG_DIR}/hcp_structural_command_${log_label}_${array_label}_${timestamp}.txt"
run_log="${LOG_DIR}/hcp_structural_run_${log_label}_${array_label}_${timestamp}.log"

cat > "$command_log" <<LOG
CONFIG_ENV=$CONFIG_ENV
HCP_IMAGE=$HCP_IMAGE
HCP_STRUCTURAL_OUT=$HCP_STRUCTURAL_OUT
HCP_STRUCTURAL_WORK=$HCP_STRUCTURAL_WORK
HCP_PROCESSING_MODE=$HCP_PROCESSING_MODE
HCP_STRUCTURAL_PARTICIPANT_LABELS=$HCP_STRUCTURAL_PARTICIPANT_LABELS
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

find_hcp_dir() {
  if [[ -n "${HCPPIPEDIR:-}" && -x "${HCPPIPEDIR}/PreFreeSurfer/PreFreeSurferPipeline.sh" ]]; then
    echo "$HCPPIPEDIR"
    return 0
  fi
  for candidate in /pipeline_tools/HCPpipelines /pipeline_tools/HCPpipelines-5.0.0 /opt/HCP-Pipelines /opt/HCPpipelines /opt/HCPpipelines-5.0.0 /usr/local/HCPpipelines /HCPpipelines; do
    if [[ -x "${candidate}/PreFreeSurfer/PreFreeSurferPipeline.sh" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  local found
  found="$(find / -path "*/PreFreeSurfer/PreFreeSurferPipeline.sh" -type f -executable -print -quit 2>/dev/null || true)"
  [[ -n "$found" ]] || return 1
  dirname "$(dirname "$found")"
}

SUBJECT="${HCP_SUBJECT}"
SESSION="${SUBJECT#sub-}"
STUDY_FOLDER="/hcp"
WORK_SUBJECT="/work/${SESSION}"
mkdir -p "$WORK_SUBJECT"

export HCPPIPEDIR
HCPPIPEDIR="$(find_hcp_dir)" || die "could not discover HCPPIPEDIR in container"
export HCPPIPEDIR_Global="${HCPPIPEDIR}/global/scripts"
export HCPPIPEDIR_Config="${HCPPIPEDIR}/global/config"
export HCPPIPEDIR_Templates="${HCPPIPEDIR}/global/templates"
export MSMCONFIGDIR="${HCPPIPEDIR}/MSMConfig"
export SUBJECTS_DIR="${STUDY_FOLDER}/${SESSION}/T1w"
export FS_LICENSE="/opt/freesurfer/license.txt"

mapfile -t t1w_images < <(find /data -path "*/${SUBJECT}/*" -type f -name "*_T1w.nii.gz" | sort)
mapfile -t t2w_images < <(find /data -path "*/${SUBJECT}/*" -type f -name "*_T2w.nii.gz" | sort)
[[ "${#t1w_images[@]}" -gt 0 ]] || die "no T1w images found for ${SUBJECT} under /data"
T1W_LIST="$(join_by_at "${t1w_images[@]}")"
if [[ "${#t2w_images[@]}" -gt 0 ]]; then
  T2W_LIST="$(join_by_at "${t2w_images[@]}")"
else
  T2W_LIST="NONE"
  HCP_PROCESSING_MODE="LegacyStyleData"
fi

T1wTemplate="${HCPPIPEDIR_Templates}/MNI152_T1_0.7mm.nii.gz"
T1wTemplateBrain="${HCPPIPEDIR_Templates}/MNI152_T1_0.7mm_brain.nii.gz"
T1wTemplate2mm="${HCPPIPEDIR_Templates}/MNI152_T1_2mm.nii.gz"
T2wTemplate="${HCPPIPEDIR_Templates}/MNI152_T2_0.7mm.nii.gz"
T2wTemplateBrain="${HCPPIPEDIR_Templates}/MNI152_T2_0.7mm_brain.nii.gz"
T2wTemplate2mm="${HCPPIPEDIR_Templates}/MNI152_T2_2mm.nii.gz"
TemplateMask="${HCPPIPEDIR_Templates}/MNI152_T1_0.7mm_brain_mask.nii.gz"
Template2mmMask="${HCPPIPEDIR_Templates}/MNI152_T1_2mm_brain_mask_dil.nii.gz"
FNIRTConfig="${HCPPIPEDIR_Config}/T1_2_MNI152_2mm.cnf"

echo "HCPPIPEDIR=${HCPPIPEDIR}"
echo "SESSION=${SESSION}"
echo "T1W_LIST=${T1W_LIST}"
echo "T2W_LIST=${T2W_LIST}"
echo "HCP_PROCESSING_MODE=${HCP_PROCESSING_MODE}"

"${HCPPIPEDIR}/PreFreeSurfer/PreFreeSurferPipeline.sh" \
  --path="${STUDY_FOLDER}" \
  --session="${SESSION}" \
  --t1="${T1W_LIST}" \
  --t2="${T2W_LIST}" \
  --t1template="${T1wTemplate}" \
  --t1templatebrain="${T1wTemplateBrain}" \
  --t1template2mm="${T1wTemplate2mm}" \
  --t2template="${T2wTemplate}" \
  --t2templatebrain="${T2wTemplateBrain}" \
  --t2template2mm="${T2wTemplate2mm}" \
  --templatemask="${TemplateMask}" \
  --template2mmmask="${Template2mmMask}" \
  --brainsize="${HCP_BRAIN_SIZE}" \
  --fnirtconfig="${FNIRTConfig}" \
  --fmapmag="NONE" \
  --fmapphase="NONE" \
  --fmapcombined="NONE" \
  --echodiff="NONE" \
  --SEPhaseNeg="NONE" \
  --SEPhasePos="NONE" \
  --seechospacing="NONE" \
  --seunwarpdir="NONE" \
  --t1samplespacing="NONE" \
  --t2samplespacing="NONE" \
  --unwarpdir="NONE" \
  --gdcoeffs="NONE" \
  --avgrdcmethod="NONE" \
  --topupconfig="NONE" \
  --processing-mode="${HCP_PROCESSING_MODE}"

fs_cmd=(
  "${HCPPIPEDIR}/FreeSurfer/FreeSurferPipeline.sh"
  --session="${SESSION}"
  --session-dir="${STUDY_FOLDER}/${SESSION}/T1w"
  --t1w-image="${STUDY_FOLDER}/${SESSION}/T1w/T1w_acpc_dc_restore.nii.gz"
  --t1w-brain="${STUDY_FOLDER}/${SESSION}/T1w/T1w_acpc_dc_restore_brain.nii.gz"
  --processing-mode="${HCP_PROCESSING_MODE}"
)
if [[ "$T2W_LIST" != "NONE" ]]; then
  fs_cmd+=(--t2w-image="${STUDY_FOLDER}/${SESSION}/T1w/T2w_acpc_dc_restore.nii.gz")
fi
"${fs_cmd[@]}"

"${HCPPIPEDIR}/PostFreeSurfer/PostFreeSurferPipeline.sh" \
  --path="${STUDY_FOLDER}" \
  --subject="${SESSION}" \
  --surfatlasdir="${HCPPIPEDIR_Templates}/standard_mesh_atlases" \
  --grayordinatesdir="${HCPPIPEDIR_Templates}/91282_Greyordinates" \
  --grayordinatesres="${HCP_GRAYORDINATES_RES}" \
  --hiresmesh="${HCP_HIGH_RES_MESH}" \
  --lowresmesh="${HCP_LOW_RES_MESH}" \
  --subcortgraylabels="${HCPPIPEDIR_Config}/FreeSurferSubcorticalLabelTableLut.txt" \
  --freesurferlabels="${HCPPIPEDIR_Config}/FreeSurferAllLut.txt" \
  --refmyelinmaps="${HCPPIPEDIR_Templates}/standard_mesh_atlases/Conte69.MyelinMap_BC.164k_fs_LR.dscalar.nii" \
  --regname="${HCP_REG_NAME}" \
  --structural-qc="${HCP_STRUCTURAL_QC}" \
  --processing-mode="${HCP_PROCESSING_MODE}"

[[ -d "${STUDY_FOLDER}/${SESSION}/MNINonLinear" ]] || die "MNINonLinear was not created for ${SUBJECT}"
echo "HCP structural complete: ${STUDY_FOLDER}/${SESSION}/MNINonLinear"
'

  case "$CONTAINER_RUNTIME" in
    docker)
      docker run --rm \
        -e HCP_SUBJECT="$subject" \
        -e HCP_PROCESSING_MODE="$HCP_PROCESSING_MODE" \
        -e HCP_BRAIN_SIZE="${HCP_BRAIN_SIZE:-150}" \
        -e HCP_GRAYORDINATES_RES="$HCP_GRAYORDINATES_RES" \
        -e HCP_HIGH_RES_MESH="$HCP_HIGH_RES_MESH" \
        -e HCP_LOW_RES_MESH="$HCP_LOW_RES_MESH" \
        -e HCP_REG_NAME="$HCP_REG_NAME" \
        -e HCP_STRUCTURAL_QC="$HCP_STRUCTURAL_QC" \
        -v "${BIDS_DIR}:/data:ro" \
        -v "${HCP_STRUCTURAL_OUT}:/hcp" \
        -v "${HCP_STRUCTURAL_WORK}:/work" \
        -v "${FS_LICENSE}:/opt/freesurfer/license.txt:ro" \
        "$HCP_IMAGE" \
        bash -lc "$script"
      ;;
    apptainer)
      apptainer exec --cleanenv \
        "${apptainer_no_mount_args[@]}" \
        --env HCP_SUBJECT="$subject" \
        --env HCP_PROCESSING_MODE="$HCP_PROCESSING_MODE" \
        --env HCP_BRAIN_SIZE="${HCP_BRAIN_SIZE:-150}" \
        --env HCP_GRAYORDINATES_RES="$HCP_GRAYORDINATES_RES" \
        --env HCP_HIGH_RES_MESH="$HCP_HIGH_RES_MESH" \
        --env HCP_LOW_RES_MESH="$HCP_LOW_RES_MESH" \
        --env HCP_REG_NAME="$HCP_REG_NAME" \
        --env HCP_STRUCTURAL_QC="$HCP_STRUCTURAL_QC" \
        -B "${BIDS_DIR}:/data:ro" \
        -B "${HCP_STRUCTURAL_OUT}:/hcp" \
        -B "${HCP_STRUCTURAL_WORK}:/work" \
        -B "${FS_LICENSE}:/opt/freesurfer/license.txt:ro" \
        "$HCP_IMAGE" \
        bash -lc "$script"
      ;;
    singularity)
      singularity exec --cleanenv \
        "${apptainer_no_mount_args[@]}" \
        --env HCP_SUBJECT="$subject" \
        --env HCP_PROCESSING_MODE="$HCP_PROCESSING_MODE" \
        --env HCP_BRAIN_SIZE="${HCP_BRAIN_SIZE:-150}" \
        --env HCP_GRAYORDINATES_RES="$HCP_GRAYORDINATES_RES" \
        --env HCP_HIGH_RES_MESH="$HCP_HIGH_RES_MESH" \
        --env HCP_LOW_RES_MESH="$HCP_LOW_RES_MESH" \
        --env HCP_REG_NAME="$HCP_REG_NAME" \
        --env HCP_STRUCTURAL_QC="$HCP_STRUCTURAL_QC" \
        -B "${BIDS_DIR}:/data:ro" \
        -B "${HCP_STRUCTURAL_OUT}:/hcp" \
        -B "${HCP_STRUCTURAL_WORK}:/work" \
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
