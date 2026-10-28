#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_fmriprep.sh CONFIG_ENV

Runs the frozen canonical fMRIPrep workflow from MRI_Preprocessing_Plan.md.
Edit CONFIG_ENV from config/mri_preproc.env.example before use.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  exit 0
fi

CONFIG_ENV="$1"
# shellcheck source=/dev/null
source "$CONFIG_ENV"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${FMRIPREP_SINGLE_SUBJECT:-}" ]]; then
  PARTICIPANT_LABELS="$FMRIPREP_SINGLE_SUBJECT"
  subject_work_label="${FMRIPREP_SINGLE_SUBJECT#sub-}"
  WORK_DIR="${WORK_DIR}/${subject_work_label}"
fi

required_vars=(
  BIDS_DIR DERIVATIVES_DIR FMRIPREP_OUT FS_SUBJECTS_DIR WORK_DIR LOG_DIR
  FS_LICENSE CONTAINER_RUNTIME FMRIPREP_IMAGE SUBJECT_ANATOMICAL_REFERENCE
  RANDOM_SEED SLICE_TIME_REF NTHREADS OMP_NTHREADS MEM_MB
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "ERROR: $var_name is not set in $CONFIG_ENV" >&2
    exit 2
  fi
done

if [[ "${SUBJECT_ANATOMICAL_REFERENCE}" != "unbiased" ]]; then
  echo "ERROR: canonical multi-session release requires SUBJECT_ANATOMICAL_REFERENCE=unbiased" >&2
  exit 2
fi

mkdir -p "$FMRIPREP_OUT" "$FS_SUBJECTS_DIR" "$WORK_DIR" "$LOG_DIR"

fmriprep_args=(
  /data
  /out
  participant
  --subject-anatomical-reference "$SUBJECT_ANATOMICAL_REFERENCE"
  --output-spaces
  func
  T1w
  MNI152NLin2009cAsym:res-native
  fsnative
  --cifti-output
  91k
  --msm
  --slice-time-ref
  "$SLICE_TIME_REF"
  --random-seed
  "$RANDOM_SEED"
  --fs-subjects-dir
  /fs
  --nthreads
  "$NTHREADS"
  --omp-nthreads
  "$OMP_NTHREADS"
  --mem_mb
  "$MEM_MB"
  --work-dir
  /work
)
if [[ -n "${PARTICIPANT_LABELS:-}" ]]; then
  fmriprep_args+=(--participant-label)
  # shellcheck disable=SC2206
  participant_array=($PARTICIPANT_LABELS)
  participant_labels=()
  for participant in "${participant_array[@]}"; do
    participant_labels+=("${participant#sub-}")
  done
  fmriprep_args+=("${participant_labels[@]}")
fi

if [[ "${SKULL_STRIP_FIXED_SEED:-0}" == "1" ]]; then
  fmriprep_args+=(--skull-strip-fixed-seed)
fi

if [[ -n "${EXTRA_FMRIPREP_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra_args=($EXTRA_FMRIPREP_ARGS)
  fmriprep_args+=("${extra_args[@]}")
fi

if [[ -z "${TEMPLATEFLOW_HOME:-}" ]]; then
  TEMPLATEFLOW_HOME="/gscratch/fang/templateflow"
fi

docker_templateflow_args=()
apptainer_templateflow_args=()
if [[ -n "${TEMPLATEFLOW_HOME:-}" && -d "${TEMPLATEFLOW_HOME}" ]]; then
  required_template="${TEMPLATEFLOW_HOME}/tpl-MNI152NLin6Asym/tpl-MNI152NLin6Asym_res-01_T1w.nii.gz"
  if [[ ! -s "$required_template" ]]; then
    echo "ERROR: TEMPLATEFLOW_HOME is set but the cache is incomplete." >&2
    echo "Missing or empty required file: $required_template" >&2
    echo "Populate TEMPLATEFLOW_HOME with scripts/prefetch_templateflow_hyak.sh $CONFIG_ENV from an internet-enabled Hyak context, then resubmit." >&2
    exit 2
  fi
  docker_templateflow_args=(-v "${TEMPLATEFLOW_HOME}:/templateflow" -e TEMPLATEFLOW_HOME=/templateflow)
  apptainer_templateflow_args=(-B "${TEMPLATEFLOW_HOME}:/templateflow" --env TEMPLATEFLOW_HOME=/templateflow)
elif [[ -n "${TEMPLATEFLOW_HOME:-}" ]]; then
  echo "ERROR: TEMPLATEFLOW_HOME does not exist: ${TEMPLATEFLOW_HOME}" >&2
  echo "Populate TEMPLATEFLOW_HOME with scripts/prefetch_templateflow_hyak.sh $CONFIG_ENV from an internet-enabled Hyak context, then resubmit." >&2
  exit 2
fi

apptainer_no_mount_args=()
if [[ -n "${APPTAINER_NO_MOUNT:-bind-paths}" ]]; then
  apptainer_no_mount_args=(--no-mount "${APPTAINER_NO_MOUNT:-bind-paths}")
fi

export APPTAINER_BINDPATH=""
export SINGULARITY_BINDPATH=""

timestamp="$(date +%Y%m%d_%H%M%S)"
log_label="all_subjects"
if [[ -n "${FMRIPREP_SINGLE_SUBJECT:-}" ]]; then
  log_label="${FMRIPREP_SINGLE_SUBJECT}"
elif [[ -n "${PARTICIPANT_LABELS:-}" ]]; then
  log_label="$(echo "$PARTICIPANT_LABELS" | tr ' /' '__')"
fi
array_label="${SLURM_ARRAY_TASK_ID:-manual}"
command_log="${LOG_DIR}/fmriprep_command_${log_label}_${array_label}_${timestamp}.txt"
run_log="${LOG_DIR}/fmriprep_run_${log_label}_${array_label}_${timestamp}.log"

{
  echo "CONFIG_ENV=$CONFIG_ENV"
  echo "FMRIPREP_IMAGE=$FMRIPREP_IMAGE"
  echo "CONTAINER_RUNTIME=$CONTAINER_RUNTIME"
  echo "TEMPLATEFLOW_HOME=$TEMPLATEFLOW_HOME"
  echo "PARTICIPANT_LABELS=${PARTICIPANT_LABELS:-}"
  printf 'fmriprep args:'
  printf ' %q' "${fmriprep_args[@]}"
  echo
} > "$command_log"

case "$CONTAINER_RUNTIME" in
  docker)
    docker run --rm \
      -v "${BIDS_DIR}:/data:ro" \
      -v "${FMRIPREP_OUT}:/out" \
      -v "${FS_SUBJECTS_DIR}:/fs" \
      -v "${WORK_DIR}:/work" \
      -v "${FS_LICENSE}:/opt/freesurfer/license.txt:ro" \
      "${docker_templateflow_args[@]}" \
      "$FMRIPREP_IMAGE" \
      "${fmriprep_args[@]}" 2>&1 | tee "$run_log"
    ;;
  apptainer)
    apptainer run --cleanenv \
      "${apptainer_no_mount_args[@]}" \
      -B "${BIDS_DIR}:/data:ro" \
      -B "${FMRIPREP_OUT}:/out" \
      -B "${FS_SUBJECTS_DIR}:/fs" \
      -B "${WORK_DIR}:/work" \
      -B "${FS_LICENSE}:/opt/freesurfer/license.txt:ro" \
      "${apptainer_templateflow_args[@]}" \
      "$FMRIPREP_IMAGE" \
      "${fmriprep_args[@]}" 2>&1 | tee "$run_log"
    ;;
  singularity)
    singularity run --cleanenv \
      "${apptainer_no_mount_args[@]}" \
      -B "${BIDS_DIR}:/data:ro" \
      -B "${FMRIPREP_OUT}:/out" \
      -B "${FS_SUBJECTS_DIR}:/fs" \
      -B "${WORK_DIR}:/work" \
      -B "${FS_LICENSE}:/opt/freesurfer/license.txt:ro" \
      "${apptainer_templateflow_args[@]}" \
      "$FMRIPREP_IMAGE" \
      "${fmriprep_args[@]}" 2>&1 | tee "$run_log"
    ;;
  *)
    echo "ERROR: Unsupported CONTAINER_RUNTIME: $CONTAINER_RUNTIME" >&2
    exit 2
    ;;
esac

materialize_args=(--fmriprep-dir "$FMRIPREP_OUT")
if [[ -n "${FMRIPREP_SINGLE_SUBJECT:-}" ]]; then
  materialize_args+=(--participant-label "$FMRIPREP_SINGLE_SUBJECT")
elif [[ -n "${PARTICIPANT_LABELS:-}" ]]; then
  # shellcheck disable=SC2206
  materialize_participants=($PARTICIPANT_LABELS)
  for participant in "${materialize_participants[@]}"; do
    materialize_args+=(--participant-label "$participant")
  done
fi
"${script_dir}/run_python_hyak.sh" "$CONFIG_ENV" "${script_dir}/materialize_shared_anatomy.py" \
  "${materialize_args[@]}"

if [[ "${FMRIPREP_PUBLISH_TO_KOPAH:-0}" == "1" ]]; then
  for required_var in KOPAH_S3CFG KOPAH_DERIVATIVES_URI; do
    if [[ -z "${!required_var:-}" ]]; then
      echo "ERROR: $required_var is required when FMRIPREP_PUBLISH_TO_KOPAH=1." >&2
      exit 2
    fi
  done

  if [[ -n "${FMRIPREP_SINGLE_SUBJECT:-}" ]]; then
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/publish_fmriprep_subject.sh" \
      "$CONFIG_ENV" "$FMRIPREP_SINGLE_SUBJECT"
  else
    echo "ERROR: automatic Kopah publishing requires FMRIPREP_SINGLE_SUBJECT." >&2
    echo "Run subject-level Slurm tasks or publish a completed cohort explicitly." >&2
    exit 2
  fi
fi

echo "Command record: $command_log"
echo "Run log: $run_log"
