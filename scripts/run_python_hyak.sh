#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_python_hyak.sh CONFIG_ENV PYTHON_SCRIPT [ARGS...]

Runs a repository Python helper inside the configured Hyak Python container.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 2 ]]; then
  usage
  exit 0
fi

CONFIG_ENV="$1"
shift

PYTHON_SCRIPT="$1"
shift

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$CONFIG_ENV"

if [[ -z "${PYTHON_CONTAINER_IMAGE:-}" ]]; then
  echo "ERROR: PYTHON_CONTAINER_IMAGE is not set in $CONFIG_ENV" >&2
  exit 2
fi

if [[ ! -f "$PYTHON_CONTAINER_IMAGE" ]]; then
  echo "ERROR: Python container not found: $PYTHON_CONTAINER_IMAGE" >&2
  exit 2
fi

runtime="${CONTAINER_RUNTIME:-apptainer}"
if [[ "$runtime" == "docker" ]]; then
  runtime="apptainer"
fi

export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export LD_PRELOAD="${LD_PRELOAD:-}"

if command -v module >/dev/null 2>&1; then
  module load apptainer >/dev/null 2>&1 || module load singularity >/dev/null 2>&1 || true
fi

if ! command -v "$runtime" >/dev/null 2>&1; then
  if command -v apptainer >/dev/null 2>&1; then
    runtime="apptainer"
  elif command -v singularity >/dev/null 2>&1; then
    runtime="singularity"
  else
    echo "ERROR: Apptainer/Singularity is not available for Python container execution." >&2
    exit 127
  fi
fi

bind_args=()
for bind_path in "$REPO_DIR" "${SCRUBBED_PROJECT_DIR:-}" "${BIDS_DIR:-}" "${DERIVATIVES_DIR:-}" "${LOG_DIR:-}" "${PROVENANCE_DIR:-}" "/mmfs1/home/xxqian/files"; do
  if [[ -n "$bind_path" && -e "$bind_path" ]]; then
    bind_args+=(-B "${bind_path}:${bind_path}")
  fi
done

no_mount_args=()
if [[ -n "${APPTAINER_NO_MOUNT:-bind-paths}" ]]; then
  no_mount_args=(--no-mount "${APPTAINER_NO_MOUNT:-bind-paths}")
fi

export APPTAINER_BINDPATH=""
export SINGULARITY_BINDPATH=""
container_python="${PYTHON_CONTAINER_PYTHON:-python3}"

"$runtime" exec --cleanenv \
  "${no_mount_args[@]}" \
  "${bind_args[@]}" \
  "$PYTHON_CONTAINER_IMAGE" \
  /bin/sh -c '
    preferred_python="$1"
    shift
    if command -v "$preferred_python" >/dev/null 2>&1; then
      exec "$preferred_python" "$@"
    elif command -v python3 >/dev/null 2>&1; then
      exec python3 "$@"
    elif command -v python >/dev/null 2>&1; then
      exec python "$@"
    else
      echo "ERROR: neither python3 nor python was found inside the Python container." >&2
      exit 127
    fi
  ' sh "$container_python" "$PYTHON_SCRIPT" "$@"
