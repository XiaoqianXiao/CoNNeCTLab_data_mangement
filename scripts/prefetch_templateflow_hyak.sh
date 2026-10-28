#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/prefetch_templateflow_hyak.sh CONFIG_ENV

Populates the configured TemplateFlow cache before fMRIPrep production.
Defaults to the shared lab cache at /gscratch/fang/templateflow.
Run this from an internet-enabled Hyak login/data-transfer context, not inside
the fMRIPrep SLURM array.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  exit 0
fi

CONFIG_ENV="$1"
# shellcheck source=/dev/null
source "$CONFIG_ENV"

if [[ -z "${TEMPLATEFLOW_HOME:-}" ]]; then
  TEMPLATEFLOW_HOME="/gscratch/fang/templateflow"
fi

echo "TemplateFlow cache: $TEMPLATEFLOW_HOME" >&2

if [[ -z "${FMRIPREP_IMAGE:-}" || ! -f "$FMRIPREP_IMAGE" ]]; then
  echo "ERROR: FMRIPREP_IMAGE is not set or does not exist: ${FMRIPREP_IMAGE:-}" >&2
  exit 2
fi

runtime="${CONTAINER_RUNTIME:-apptainer}"
if [[ "$runtime" == "docker" ]]; then
  runtime="apptainer"
fi

if command -v module >/dev/null 2>&1; then
  module load apptainer >/dev/null 2>&1 || module load singularity >/dev/null 2>&1 || true
fi

if ! command -v "$runtime" >/dev/null 2>&1; then
  if command -v apptainer >/dev/null 2>&1; then
    runtime="apptainer"
  elif command -v singularity >/dev/null 2>&1; then
    runtime="singularity"
  else
    echo "ERROR: Apptainer/Singularity is not available." >&2
    exit 127
  fi
fi

mkdir -p "$TEMPLATEFLOW_HOME"

no_mount_args=()
dns_bind_args=()
if [[ -n "${APPTAINER_NO_MOUNT:-}" ]]; then
  no_mount_args=(--no-mount "$APPTAINER_NO_MOUNT")
  # Hyak's bind-path restriction omits the host resolver configuration.
  # Bind it explicitly so TemplateFlow downloads can resolve S3.
  dns_bind_args=(-B /etc/resolv.conf:/etc/resolv.conf:ro)
fi

export APPTAINER_BINDPATH=""
export SINGULARITY_BINDPATH=""

"$runtime" exec --cleanenv \
  "${no_mount_args[@]}" \
  "${dns_bind_args[@]}" \
  -B "${TEMPLATEFLOW_HOME}:/templateflow" \
  --env TEMPLATEFLOW_HOME=/templateflow \
  "$FMRIPREP_IMAGE" \
  python - <<'PY'
from pathlib import Path
import socket
import sys

import requests
from templateflow import api as tf

host = "templateflow.s3.amazonaws.com"
try:
    socket.getaddrinfo(host, 443)
except OSError as exc:
    print(
        f"ERROR: cannot resolve {host} from this Hyak context: {exc}\n"
        "Run this command from a login/data-transfer node or another "
        "environment with internet/DNS access. The scripts will use "
        "TEMPLATEFLOW_HOME after it is populated.",
        file=sys.stderr,
    )
    raise SystemExit(2)

templates = [
    "MNI152NLin6Asym",
    "MNI152NLin2009cAsym",
    "OASIS30ANTs",
    "fsaverage",
    "fsLR",
]

for template in templates:
    print(f"Fetching TemplateFlow template: {template}", flush=True)
    try:
        files = tf.get(template, raise_empty=True)
    except requests.RequestException as exc:
        print(
            f"ERROR: failed to download TemplateFlow template {template}: {exc}\n"
            "Run this command from an internet-enabled context, or copy "
            "an already-populated TemplateFlow cache into TEMPLATEFLOW_HOME.",
            file=sys.stderr,
        )
        raise SystemExit(2)
    if isinstance(files, (str, Path)):
        files = [files]
    print(f"  cached {len(files)} files", flush=True)

required = Path("/templateflow/tpl-MNI152NLin6Asym/tpl-MNI152NLin6Asym_res-01_T1w.nii.gz")
if not required.is_file() or required.stat().st_size == 0:
    raise SystemExit(f"Required TemplateFlow file is missing or empty: {required}")

print("TemplateFlow cache is ready.", flush=True)
PY
