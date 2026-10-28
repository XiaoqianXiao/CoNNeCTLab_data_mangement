#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_bids_validator.sh CONFIG_ENV

Runs the BIDS validator before fMRIPrep production.
Requires Docker, Apptainer, Singularity, or a local bids-validator command.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  exit 0
fi

CONFIG_ENV="$1"
# shellcheck source=/dev/null
source "$CONFIG_ENV"

mkdir -p "$LOG_DIR"
REPORT="${LOG_DIR}/bids-validator_$(date +%Y%m%d_%H%M%S).log"

if command -v bids-validator >/dev/null 2>&1; then
  bids-validator "$BIDS_DIR" | tee "$REPORT"
else
  runtime="${CONTAINER_RUNTIME:-apptainer}"
  case "$runtime" in
    docker)
      command -v docker >/dev/null 2>&1 || {
        echo "ERROR: Docker is not available." >&2
        exit 127
      }
      docker run --rm -v "${BIDS_DIR}:/data:ro" bids/validator /data | tee "$REPORT"
      ;;
    apptainer|singularity)
      command -v "$runtime" >/dev/null 2>&1 || {
        echo "ERROR: Requested container runtime is not available: $runtime" >&2
        exit 127
      }
      no_mount_args=()
      if [[ -n "${APPTAINER_NO_MOUNT:-bind-paths}" ]]; then
        no_mount_args=(--no-mount "${APPTAINER_NO_MOUNT:-bind-paths}")
      fi
      BIDS_VALIDATOR_CACHE_DIR="${BIDS_VALIDATOR_CACHE_DIR:-${LOG_DIR}/bids-validator-deno-cache}"
      mkdir -p "$BIDS_VALIDATOR_CACHE_DIR"
      "$runtime" run "${no_mount_args[@]}" \
        -B "${BIDS_DIR}:/data:ro" \
        -B "${BIDS_VALIDATOR_CACHE_DIR}:/deno-dir" \
        docker://bids/validator /data | tee "$REPORT"
      ;;
    *)
      echo "ERROR: Unsupported CONTAINER_RUNTIME: $runtime" >&2
      exit 2
      ;;
  esac
fi

echo "BIDS validator report: $REPORT"
