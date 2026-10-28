#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_hippunfold.sh CONFIG_ENV

Runs the separate HippUnfold derivative branch. For SLURM arrays, the worker
sets HIPPUNFOLD_SINGLE_SUBJECT and this script runs one participant.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  exit 0
fi

CONFIG_ENV="$1"
# shellcheck source=/dev/null
source "$CONFIG_ENV"

HIPPUNFOLD_OUT="${HIPPUNFOLD_OUT:-${DERIVATIVES_DIR}/hippunfold}"
HIPPUNFOLD_WORK="${HIPPUNFOLD_WORK:-${WORK_ROOT:-${SCRUBBED_PROJECT_DIR}/scratch}/hippunfold}"
HIPPUNFOLD_CACHE_DIR="${HIPPUNFOLD_CACHE_DIR:-${SCRUBBED_PROJECT_DIR}/cache/hippunfold}"
HIPPUNFOLD_TMPDIR="${HIPPUNFOLD_TMPDIR:-${HIPPUNFOLD_WORK}/tmp}"
HIPPUNFOLD_PARTICIPANT_LABELS="${HIPPUNFOLD_PARTICIPANT_LABELS:-}"
HIPPUNFOLD_MODALITY="${HIPPUNFOLD_MODALITY:-T1w}"
HIPPUNFOLD_TEMPLATE="${HIPPUNFOLD_TEMPLATE:-CITI168}"
HIPPUNFOLD_INJECT_TEMPLATE="${HIPPUNFOLD_INJECT_TEMPLATE:-upenn}"
HIPPUNFOLD_BUILTIN_ATLAS="${HIPPUNFOLD_BUILTIN_ATLAS:-multihist7}"
HIPPUNFOLD_CORES="${HIPPUNFOLD_CORES:-${NTHREADS:-all}}"
HIPPUNFOLD_CONTAINER_ENTRYPOINT="${HIPPUNFOLD_CONTAINER_ENTRYPOINT:-/app/entrypoint.sh}"
HIPPUNFOLD_CONTAINER_COMMAND="${HIPPUNFOLD_CONTAINER_COMMAND:-hippunfold}"
HIPPUNFOLD_REQUIRE_CACHED_MODEL="${HIPPUNFOLD_REQUIRE_CACHED_MODEL:-1}"
HIPPUNFOLD_REQUIRE_CACHED_RESOURCES="${HIPPUNFOLD_REQUIRE_CACHED_RESOURCES:-1}"
if [[ -n "${HIPPUNFOLD_SINGLE_SUBJECT:-}" ]]; then
  HIPPUNFOLD_PARTICIPANT_LABELS="$HIPPUNFOLD_SINGLE_SUBJECT"
  HIPPUNFOLD_WORK="${HIPPUNFOLD_WORK}/${HIPPUNFOLD_SINGLE_SUBJECT#sub-}"
  HIPPUNFOLD_TMPDIR="${HIPPUNFOLD_TMPDIR}/${HIPPUNFOLD_SINGLE_SUBJECT#sub-}"
fi

required_vars=(BIDS_DIR DERIVATIVES_DIR LOG_DIR HIPPUNFOLD_OUT HIPPUNFOLD_WORK HIPPUNFOLD_CACHE_DIR HIPPUNFOLD_TMPDIR HIPPUNFOLD_IMAGE CONTAINER_RUNTIME HIPPUNFOLD_MODALITY HIPPUNFOLD_TEMPLATE HIPPUNFOLD_INJECT_TEMPLATE HIPPUNFOLD_BUILTIN_ATLAS HIPPUNFOLD_CORES HIPPUNFOLD_CONTAINER_ENTRYPOINT HIPPUNFOLD_CONTAINER_COMMAND)
for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "ERROR: $var_name is not set in $CONFIG_ENV" >&2
    exit 2
  fi
done

if [[ ! -d "$BIDS_DIR" ]]; then
  echo "ERROR: BIDS_DIR does not exist: $BIDS_DIR" >&2
  exit 2
fi
if [[ ! -f "$HIPPUNFOLD_IMAGE" ]]; then
  echo "ERROR: HIPPUNFOLD_IMAGE does not exist: $HIPPUNFOLD_IMAGE" >&2
  exit 2
fi

hippunfold_model_file() {
  case "$1" in
    T1w) echo "trained_model.3d_fullres.Task101_hcp1200_T1w.nnUNetTrainerV2.model_best.tar" ;;
    T2w) echo "trained_model.3d_fullres.Task102_hcp1200_T2w.nnUNetTrainerV2.model_best.tar" ;;
    b1000|b1000crop) echo "trained_model.3d_fullres.Task110_hcp1200_b1000crop.nnUNetTrainerV2.model_best.tar" ;;
    *) echo "" ;;
  esac
}

mkdir -p "$HIPPUNFOLD_OUT" "$HIPPUNFOLD_WORK" "$HIPPUNFOLD_CACHE_DIR" "$HIPPUNFOLD_TMPDIR" "$LOG_DIR" "${HIPPUNFOLD_OUT}/.snakemake" "${HIPPUNFOLD_OUT}/config"

required_model="${HIPPUNFOLD_REQUIRED_MODEL:-$(hippunfold_model_file "$HIPPUNFOLD_MODALITY")}"
required_model_tar="${HIPPUNFOLD_CACHE_DIR}/model/${required_model}"
if [[ "$HIPPUNFOLD_REQUIRE_CACHED_MODEL" == "1" && -n "$required_model" && ! -f "$required_model_tar" ]]; then
  cat >&2 <<MSG
ERROR: HippUnfold model is not cached: $required_model_tar

Compute nodes may not have internet/DNS access, so HippUnfold cannot download
models during array jobs. Run this from an internet-enabled Hyak login or
data-transfer context before resubmitting:

  scripts/prefetch_hippunfold_models_hyak.sh ${CONFIG_ENV}

Set HIPPUNFOLD_REQUIRE_CACHED_MODEL=0 only for a deliberate online test.
MSG
  exit 2
fi
atlas_dir="${HIPPUNFOLD_CACHE_DIR}/atlases_dl/tpl-${HIPPUNFOLD_BUILTIN_ATLAS}"
atlas_cache_dir="${HIPPUNFOLD_CACHE_DIR}/atlas/${HIPPUNFOLD_BUILTIN_ATLAS}"
atlases_cache_dir="${HIPPUNFOLD_CACHE_DIR}/atlases/tpl-${HIPPUNFOLD_BUILTIN_ATLAS}"
template_dir="${HIPPUNFOLD_CACHE_DIR}/template/${HIPPUNFOLD_TEMPLATE}"
inject_template_dir="${HIPPUNFOLD_CACHE_DIR}/template/${HIPPUNFOLD_INJECT_TEMPLATE}"
if [[ "$HIPPUNFOLD_REQUIRE_CACHED_RESOURCES" == "1" ]]; then
  for resource_dir in "$atlas_dir" "$atlas_cache_dir" "$atlases_cache_dir" "$template_dir" "$inject_template_dir"; do
    if [[ ! -d "$resource_dir" || -z "$(find "$resource_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      cat >&2 <<MSG
ERROR: HippUnfold resource cache is missing or empty: $resource_dir

Compute nodes may not have internet/DNS access, so HippUnfold cannot download
atlases or templates during array jobs. Run this before resubmitting:

  scripts/prefetch_hippunfold_models_hyak.sh ${CONFIG_ENV}

Set HIPPUNFOLD_REQUIRE_CACHED_RESOURCES=0 only for a deliberate online test.
MSG
      exit 2
    fi
    if [[ ! -f "${resource_dir}/.snakemake_timestamp" ]]; then
      cat >&2 <<MSG
ERROR: HippUnfold resource cache is missing Snakemake's directory marker: ${resource_dir}/.snakemake_timestamp

Run the prefetch helper once with the updated script before resubmitting:

  scripts/prefetch_hippunfold_models_hyak.sh ${CONFIG_ENV}

This prevents array jobs from trying to rebuild shared resource directories.
MSG
      exit 2
    fi
  done
fi

snakebids_marker="${HIPPUNFOLD_WORK}/.snakebids"
snakemake_metadata="${HIPPUNFOLD_WORK}/.snakemake"
snakebids_config="${HIPPUNFOLD_WORK}/config"
mkdir -p "${snakemake_metadata}/locks" "$snakebids_config"
if [[ ! -s "$snakebids_marker" ]]; then
  tmp_marker="${snakebids_marker}.tmp.$$"
  printf '%s\n' '{"mode":"bidsapp"}' > "$tmp_marker"
  mv "$tmp_marker" "$snakebids_marker"
fi
if ! python3 - "$snakebids_marker" <<'PY'
import json
import sys
from pathlib import Path

marker = Path(sys.argv[1])
try:
    data = json.loads(marker.read_text())
except json.JSONDecodeError as exc:
    raise SystemExit(f"ERROR: invalid Snakebids marker {marker}: {exc}")
if data.get("mode") != "bidsapp":
    raise SystemExit(f"ERROR: unexpected Snakebids marker mode in {marker}: {data!r}")
PY
then
  exit 2
fi

hippunfold_args=(/data /out participant --modality "$HIPPUNFOLD_MODALITY" --template "$HIPPUNFOLD_TEMPLATE" --inject_template "$HIPPUNFOLD_INJECT_TEMPLATE" --cores "$HIPPUNFOLD_CORES")
if [[ -n "$HIPPUNFOLD_PARTICIPANT_LABELS" ]]; then
  hippunfold_args+=(--participant-label)
  # shellcheck disable=SC2206
  participant_array=($HIPPUNFOLD_PARTICIPANT_LABELS)
  for participant in "${participant_array[@]}"; do
    hippunfold_args+=("${participant#sub-}")
  done
fi
if [[ -n "${EXTRA_HIPPUNFOLD_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra_args=($EXTRA_HIPPUNFOLD_ARGS)
  hippunfold_args+=("${extra_args[@]}")
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
log_label="${HIPPUNFOLD_PARTICIPANT_LABELS:-all_subjects}"
log_label="$(echo "$log_label" | tr ' /' '__')"
array_label="${SLURM_ARRAY_TASK_ID:-manual}"
command_log="${LOG_DIR}/hippunfold_command_${log_label}_${array_label}_${timestamp}.txt"
run_log="${LOG_DIR}/hippunfold_run_${log_label}_${array_label}_${timestamp}.log"

{
  echo "CONFIG_ENV=$CONFIG_ENV"
  echo "HIPPUNFOLD_IMAGE=$HIPPUNFOLD_IMAGE"
  echo "CONTAINER_RUNTIME=$CONTAINER_RUNTIME"
  echo "HIPPUNFOLD_CACHE_DIR=$HIPPUNFOLD_CACHE_DIR"
  echo "HIPPUNFOLD_TMPDIR=$HIPPUNFOLD_TMPDIR"
  echo "SNAKEBIDS_MARKER=$snakebids_marker"
  echo "SNAKEMAKE_METADATA=$snakemake_metadata"
  echo "SNAKEBIDS_CONFIG=$snakebids_config"
  echo "HIPPUNFOLD_PARTICIPANT_LABELS=$HIPPUNFOLD_PARTICIPANT_LABELS"
  echo "HIPPUNFOLD_MODALITY=$HIPPUNFOLD_MODALITY"
  echo "HIPPUNFOLD_TEMPLATE=$HIPPUNFOLD_TEMPLATE"
  echo "HIPPUNFOLD_INJECT_TEMPLATE=$HIPPUNFOLD_INJECT_TEMPLATE"
  echo "HIPPUNFOLD_BUILTIN_ATLAS=$HIPPUNFOLD_BUILTIN_ATLAS"
  echo "HIPPUNFOLD_CORES=$HIPPUNFOLD_CORES"
  echo "HIPPUNFOLD_REQUIRED_MODEL=$required_model"
  echo "HIPPUNFOLD_CONTAINER_ENTRYPOINT=$HIPPUNFOLD_CONTAINER_ENTRYPOINT"
  echo "HIPPUNFOLD_CONTAINER_COMMAND=$HIPPUNFOLD_CONTAINER_COMMAND"
  printf 'hippunfold args:'
  printf ' %q' "${hippunfold_args[@]}"
  echo
} > "$command_log"

case "$CONTAINER_RUNTIME" in
  docker)
    docker run --rm \
      -v "${BIDS_DIR}:/data:ro" \
      -v "${HIPPUNFOLD_OUT}:/out" \
      -v "${HIPPUNFOLD_WORK}:/work" \
      -v "${HIPPUNFOLD_TMPDIR}:/tmp" \
      -v "${HIPPUNFOLD_CACHE_DIR}:/hippunfold_cache" \
      -v "${snakebids_marker}:/out/.snakebids" \
      -v "${snakemake_metadata}:/out/.snakemake" \
      -v "${snakebids_config}:/out/config" \
      -e HIPPUNFOLD_CACHE_DIR=/hippunfold_cache \
      -e TMPDIR=/tmp \
      -e TEMP=/tmp \
      -e TMP=/tmp \
      -e XDG_CACHE_HOME=/hippunfold_cache/xdg \
      "$HIPPUNFOLD_IMAGE" \
      "$HIPPUNFOLD_CONTAINER_COMMAND" \
      "${hippunfold_args[@]}" 2>&1 | tee "$run_log"
    ;;
  apptainer)
    apptainer exec --cleanenv \
      "${apptainer_no_mount_args[@]}" \
      -B "${BIDS_DIR}:/data:ro" \
      -B "${HIPPUNFOLD_OUT}:/out" \
      -B "${HIPPUNFOLD_WORK}:/work" \
      -B "${HIPPUNFOLD_TMPDIR}:/tmp" \
      -B "${HIPPUNFOLD_CACHE_DIR}:/hippunfold_cache" \
      -B "${snakebids_marker}:/out/.snakebids" \
      -B "${snakemake_metadata}:/out/.snakemake" \
      -B "${snakebids_config}:/out/config" \
      --env HIPPUNFOLD_CACHE_DIR=/hippunfold_cache \
      --env TMPDIR=/tmp \
      --env TEMP=/tmp \
      --env TMP=/tmp \
      --env XDG_CACHE_HOME=/hippunfold_cache/xdg \
      "$HIPPUNFOLD_IMAGE" \
      "$HIPPUNFOLD_CONTAINER_ENTRYPOINT" \
      "$HIPPUNFOLD_CONTAINER_COMMAND" \
      "${hippunfold_args[@]}" 2>&1 | tee "$run_log"
    ;;
  singularity)
    singularity exec --cleanenv \
      "${apptainer_no_mount_args[@]}" \
      -B "${BIDS_DIR}:/data:ro" \
      -B "${HIPPUNFOLD_OUT}:/out" \
      -B "${HIPPUNFOLD_WORK}:/work" \
      -B "${HIPPUNFOLD_TMPDIR}:/tmp" \
      -B "${HIPPUNFOLD_CACHE_DIR}:/hippunfold_cache" \
      -B "${snakebids_marker}:/out/.snakebids" \
      -B "${snakemake_metadata}:/out/.snakemake" \
      -B "${snakebids_config}:/out/config" \
      --env HIPPUNFOLD_CACHE_DIR=/hippunfold_cache \
      --env TMPDIR=/tmp \
      --env TEMP=/tmp \
      --env TMP=/tmp \
      --env XDG_CACHE_HOME=/hippunfold_cache/xdg \
      "$HIPPUNFOLD_IMAGE" \
      "$HIPPUNFOLD_CONTAINER_ENTRYPOINT" \
      "$HIPPUNFOLD_CONTAINER_COMMAND" \
      "${hippunfold_args[@]}" 2>&1 | tee "$run_log"
    ;;
  *)
    echo "ERROR: Unsupported CONTAINER_RUNTIME: $CONTAINER_RUNTIME" >&2
    exit 2
    ;;
esac

echo "Command record: $command_log"
echo "Run log: $run_log"
