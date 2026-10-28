#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/submit_hcp_structural_array_hyak.sh CONFIG_ENV

Submits one HCP structural preprocessing SLURM array task per BIDS subject.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  exit 0
fi

CONFIG_ENV="$1"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

if [[ "$CONFIG_ENV" != /* ]]; then
  CONFIG_ENV="${REPO_DIR}/${CONFIG_ENV}"
fi

# shellcheck source=/dev/null
source "$CONFIG_ENV"

HCP_STRUCTURAL_OUT="${HCP_STRUCTURAL_OUT:-${DERIVATIVES_DIR}/hcp}"
HCP_STRUCTURAL_WORK="${HCP_STRUCTURAL_WORK:-${WORK_ROOT:-${SCRUBBED_PROJECT_DIR}/scratch}/hcp-structural}"
mkdir -p "${LOG_ROOT:-/gscratch/scrubbed/fanglab/xiaoqian/IFOCUS/logs}/slurm/hcp-structural" "$LOG_DIR" "$HCP_STRUCTURAL_OUT" "$HCP_STRUCTURAL_WORK"

if [[ ! -d "$BIDS_DIR" ]]; then
  echo "ERROR: BIDS_DIR does not exist: $BIDS_DIR" >&2
  exit 2
fi

timestamp="$(date +%Y%m%d_%H%M%S)"
subject_list="${LOG_DIR}/hcp_structural_subjects_${timestamp}.txt"
find "$BIDS_DIR" -maxdepth 1 -type d -name 'sub-*' -exec basename {} \; | sort > "$subject_list"
subject_count="$(wc -l < "$subject_list" | tr -d ' ')"
if [[ "$subject_count" -eq 0 ]]; then
  echo "ERROR: no eligible sub-* directories found in BIDS_DIR: $BIDS_DIR" >&2
  exit 2
fi

last_index="$((subject_count - 1))"

echo "Subject list: $subject_list"
echo "Subject count: $subject_count"
echo "Array range: 0-${last_index}"

sbatch \
  --array="0-${last_index}" \
  --partition="${HYAK_PARTITION:?ERROR: HYAK_PARTITION must be set in the config}" \
  --time="${HCP_STRUCTURAL_HYAK_TIME:-72:00:00}" \
  "${REPO_DIR}/scripts/submit_hcp_structural_hyak.sbatch" \
  "$CONFIG_ENV" \
  "$subject_list"
