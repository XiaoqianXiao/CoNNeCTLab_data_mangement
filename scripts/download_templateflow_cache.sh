#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/download_templateflow_cache.sh [OUTPUT_DIR]

Downloads the TemplateFlow templates needed by this fMRIPrep workflow and
packages them as templateflow.tar.gz.

Run this on a machine with internet access. Then copy templateflow.tar.gz to
Hyak and extract it into the shared TemplateFlow cache parent directory.

Examples:
  scripts/download_templateflow_cache.sh
  scripts/download_templateflow_cache.sh /tmp/templateflow_download
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -gt 1 ]]; then
  usage
  exit 0
fi

OUTPUT_DIR="${1:-$(pwd)/templateflow_download}"
CACHE_DIR="${OUTPUT_DIR}/templateflow"
ARCHIVE="${OUTPUT_DIR}/templateflow.tar.gz"
VENV_DIR="${OUTPUT_DIR}/tfenv"

mkdir -p "$OUTPUT_DIR"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required." >&2
  exit 127
fi
PYTHON="$(command -v python3)"

export TEMPLATEFLOW_HOME="$CACHE_DIR"

"$PYTHON" -m venv "$VENV_DIR"
# shellcheck source=/dev/null
source "${VENV_DIR}/bin/activate"

python -m pip install --upgrade pip
python -m pip install templateflow requests

python - <<'PY'
from pathlib import Path
import os
from templateflow import api as tf

templates = [
    "MNI152NLin6Asym",
    "MNI152NLin2009cAsym",
    "OASIS30ANTs",
    "fsaverage",
    "fsLR",
]

for template in templates:
    print(f"Downloading {template}", flush=True)
    files = tf.get(template, raise_empty=True)
    if isinstance(files, (str, Path)):
        files = [files]
    print(f"  cached {len(files)} files", flush=True)

required = Path(os.environ["TEMPLATEFLOW_HOME"]) / "tpl-MNI152NLin6Asym" / "tpl-MNI152NLin6Asym_res-01_T1w.nii.gz"
if not required.is_file() or required.stat().st_size == 0:
    raise SystemExit(f"Required TemplateFlow file is missing or empty: {required}")

print(f"Done. TEMPLATEFLOW_HOME={os.environ['TEMPLATEFLOW_HOME']}", flush=True)
PY

tar -C "$OUTPUT_DIR" -czf "$ARCHIVE" templateflow

echo "TemplateFlow cache: $CACHE_DIR"
echo "Archive: $ARCHIVE"
echo
echo "Copy to Hyak:"
echo "  scp $ARCHIVE YOUR_HYAK_USER@klone.hyak.uw.edu:/gscratch/fang/"
echo
echo "Extract on Hyak:"
echo "  cd /gscratch/fang"
echo "  tar -xzf templateflow.tar.gz"
