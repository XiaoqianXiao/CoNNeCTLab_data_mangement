#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_dataset_info_report_hyak.sh CONFIG_ENV [OUTPUT_CSV]

Reports basic BIDS dataset information using the configured Hyak Python
container. If OUTPUT_CSV is omitted, the CSV is written to:
  ${PROVENANCE_DIR}/dataset_info.csv

The script writes OUTPUT_CSV as the session-level report and also writes
companion group, subject, and run-inventory CSV files next to it.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 0
fi

CONFIG_ENV="$1"
OUTPUT_CSV="${2:-}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
source "$CONFIG_ENV"

if [[ -z "${BIDS_DIR:-}" ]]; then
  echo "ERROR: BIDS_DIR is not set in $CONFIG_ENV" >&2
  exit 2
fi

if [[ -z "$OUTPUT_CSV" ]]; then
  if [[ -z "${PROVENANCE_DIR:-}" ]]; then
    echo "ERROR: PROVENANCE_DIR is not set in $CONFIG_ENV; pass OUTPUT_CSV explicitly." >&2
    exit 2
  fi
  OUTPUT_CSV="${PROVENANCE_DIR}/dataset_info.csv"
fi

"${REPO_DIR}/scripts/run_python_hyak.sh" "$CONFIG_ENV" \
  "${REPO_DIR}/scripts/report_dataset_info.py" \
  "$BIDS_DIR" \
  --csv "$OUTPUT_CSV"
