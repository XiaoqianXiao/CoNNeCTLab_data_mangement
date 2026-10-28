#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_ENV="${1:-${SCRIPT_DIR}/../config/CoNNeCTLab_data_management.env}"
if [[ "$CONFIG_ENV" != /* ]]; then
  CONFIG_ENV="$(cd "${SCRIPT_DIR}/.." && pwd)/${CONFIG_ENV}"
fi
# shellcheck source=/dev/null
source "$CONFIG_ENV"

cd "${SCRUBBED_PROJECT_DIR:?ERROR: SCRUBBED_PROJECT_DIR must be set in the config}/sourcedata/dicom"

find . -name "*.dicom.zip" | while read z; do
  d=$(dirname "$z")
  echo "Unzipping $z"
  unzip -n "$z" -d "$d"
done
