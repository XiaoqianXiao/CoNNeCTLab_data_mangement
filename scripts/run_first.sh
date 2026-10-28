#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_first.sh CONFIG_ENV

Runs the separate FSL FIRST deep-gray derivative branch from fMRIPrep T1w
anatomical outputs. For arrays, FIRST_SINGLE_SUBJECT selects one participant.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  exit 0
fi

CONFIG_ENV="$1"
# shellcheck source=/dev/null
source "$CONFIG_ENV"

FIRST_OUT="${FIRST_OUT:-${DERIVATIVES_DIR}/first}"
FIRST_WORK="${FIRST_WORK:-${WORK_ROOT:-${SCRUBBED_PROJECT_DIR}/scratch}/first}"
FIRST_PARTICIPANT_LABELS="${FIRST_PARTICIPANT_LABELS:-}"
FIRST_T1W_GLOB="${FIRST_T1W_GLOB:-anat/*desc-preproc_T1w.nii.gz}"
if [[ -n "${FIRST_SINGLE_SUBJECT:-}" ]]; then
  FIRST_PARTICIPANT_LABELS="$FIRST_SINGLE_SUBJECT"
  FIRST_WORK="${FIRST_WORK}/${FIRST_SINGLE_SUBJECT#sub-}"
fi

required_vars=(FMRIPREP_OUT DERIVATIVES_DIR LOG_DIR FIRST_OUT FIRST_WORK FIRST_IMAGE CONTAINER_RUNTIME)
for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "ERROR: $var_name is not set in $CONFIG_ENV" >&2
    exit 2
  fi
done
if [[ ! -d "$FMRIPREP_OUT" ]]; then
  echo "ERROR: FMRIPREP_OUT does not exist: $FMRIPREP_OUT" >&2
  exit 2
fi
if [[ ! -f "$FIRST_IMAGE" ]]; then
  echo "ERROR: FIRST_IMAGE does not exist: $FIRST_IMAGE" >&2
  exit 2
fi

mkdir -p "$FIRST_OUT" "$FIRST_WORK" "$LOG_DIR"

if [[ -n "$FIRST_PARTICIPANT_LABELS" ]]; then
  # shellcheck disable=SC2206
  subjects=($FIRST_PARTICIPANT_LABELS)
else
  mapfile -t subjects < <(find "$FMRIPREP_OUT" -maxdepth 1 -type d -name 'sub-*' -exec basename {} \; | sort)
fi
if [[ "${#subjects[@]}" -eq 0 ]]; then
  echo "ERROR: no fMRIPrep subject directories found." >&2
  exit 2
fi

apptainer_no_mount_args=()
if [[ -n "${APPTAINER_NO_MOUNT:-bind-paths}" ]]; then
  apptainer_no_mount_args=(--no-mount "${APPTAINER_NO_MOUNT:-bind-paths}")
fi

export APPTAINER_BINDPATH=""
export SINGULARITY_BINDPATH=""
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export LD_PRELOAD="${LD_PRELOAD:-}"

timestamp="$(date +%Y%m%d_%H%M%S)"
log_label="$(echo "${FIRST_PARTICIPANT_LABELS:-all_subjects}" | tr ' /' '__')"
array_label="${SLURM_ARRAY_TASK_ID:-manual}"
command_log="${LOG_DIR}/first_command_${log_label}_${array_label}_${timestamp}.txt"
run_log="${LOG_DIR}/first_run_${log_label}_${array_label}_${timestamp}.log"

{
  echo "CONFIG_ENV=$CONFIG_ENV"
  echo "FIRST_IMAGE=$FIRST_IMAGE"
  echo "CONTAINER_RUNTIME=$CONTAINER_RUNTIME"
  echo "FIRST_PARTICIPANT_LABELS=$FIRST_PARTICIPANT_LABELS"
  echo "FIRST_T1W_GLOB=$FIRST_T1W_GLOB"
} > "$command_log"

run_one_subject() {
  local subject="$1"
  subject="${subject#sub-}"
  subject="sub-${subject}"
  local subject_dir="${FMRIPREP_OUT}/${subject}"
  local first_subject_out="${FIRST_OUT}/${subject}"
  local first_subject_work="${FIRST_WORK}/${subject}"
  mkdir -p "$first_subject_out" "$first_subject_work"

  mapfile -t t1w_candidates < <(
    find "$subject_dir" -path "${subject_dir}/${FIRST_T1W_GLOB}" -type f ! -name '*_space-*' | sort
  )
  if [[ "${#t1w_candidates[@]}" -eq 0 ]]; then
    echo "ERROR: no T1w candidate found for $subject using ${subject_dir}/${FIRST_T1W_GLOB}" >&2
    return 2
  fi
  if [[ "${#t1w_candidates[@]}" -gt 1 ]]; then
    echo "ERROR: multiple T1w candidates found for $subject; set FIRST_T1W_GLOB more specifically." >&2
    printf '%s\n' "${t1w_candidates[@]}" >&2
    return 2
  fi

  local rel_t1w="${t1w_candidates[0]#${FMRIPREP_OUT}/}"
  local first_prefix="/out/${subject}/${subject}_first"
  local first_args=(run_first_all -i "/fmriprep/${rel_t1w}" -o "$first_prefix")
  if [[ -n "${EXTRA_FIRST_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    extra_args=($EXTRA_FIRST_ARGS)
    first_args+=("${extra_args[@]}")
  fi

  {
    printf 'first args for %s:' "$subject"
    printf ' %q' "${first_args[@]}"
    echo
  } >> "$command_log"

  case "$CONTAINER_RUNTIME" in
    docker)
      docker run --rm \
        -v "${FMRIPREP_OUT}:/fmriprep:ro" \
        -v "${first_subject_out}:/out/${subject}" \
        -v "${first_subject_work}:/work" \
        "$FIRST_IMAGE" \
        "${first_args[@]}"
      ;;
    apptainer)
      apptainer exec --cleanenv \
        "${apptainer_no_mount_args[@]}" \
        -B "${FMRIPREP_OUT}:/fmriprep:ro" \
        -B "${first_subject_out}:/out/${subject}" \
        -B "${first_subject_work}:/work" \
        "$FIRST_IMAGE" \
        "${first_args[@]}"
      ;;
    singularity)
      singularity exec --cleanenv \
        "${apptainer_no_mount_args[@]}" \
        -B "${FMRIPREP_OUT}:/fmriprep:ro" \
        -B "${first_subject_out}:/out/${subject}" \
        -B "${first_subject_work}:/work" \
        "$FIRST_IMAGE" \
        "${first_args[@]}"
      ;;
    *)
      echo "ERROR: Unsupported CONTAINER_RUNTIME: $CONTAINER_RUNTIME" >&2
      return 2
      ;;
  esac
}

for subject in "${subjects[@]}"; do
  run_one_subject "$subject"
done 2>&1 | tee "$run_log"

echo "Command record: $command_log"
echo "Run log: $run_log"
