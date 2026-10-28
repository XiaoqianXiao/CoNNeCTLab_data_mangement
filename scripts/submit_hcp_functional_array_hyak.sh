#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/submit_hcp_functional_array_hyak.sh CONFIG_ENV

Submits one HCP functional/FIX preprocessing SLURM array task per subject that
already has HCP structural MNINonLinear outputs.
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
HCP_FUNCTIONAL_WORK="${HCP_FUNCTIONAL_WORK:-${WORK_ROOT:-${SCRUBBED_PROJECT_DIR}/scratch}/hcp-functional}"
mkdir -p "${LOG_ROOT:?ERROR: LOG_ROOT must be set in the config}/slurm/hcp-functional" "$LOG_DIR" "$HCP_FUNCTIONAL_WORK"

if [[ ! -d "$BIDS_DIR" ]]; then
  echo "ERROR: BIDS_DIR does not exist: $BIDS_DIR" >&2
  exit 2
fi
if [[ ! -d "$HCP_STRUCTURAL_OUT" ]]; then
  echo "ERROR: HCP_STRUCTURAL_OUT does not exist: $HCP_STRUCTURAL_OUT" >&2
  echo "Run scripts/submit_hcp_structural_array_hyak.sh first." >&2
  exit 2
fi

timestamp="$(date +%Y%m%d_%H%M%S)"
subject_list="${LOG_DIR}/hcp_functional_subjects_${timestamp}.txt"

find "$BIDS_DIR" -maxdepth 1 -type d -name 'sub-*' -exec basename {} \; | while read -r subject; do
  session="${subject#sub-}"
  if [[ -d "${HCP_STRUCTURAL_OUT}/${session}/MNINonLinear" || -d "${HCP_STRUCTURAL_OUT}/${subject}/MNINonLinear" ]]; then
    echo "$subject"
  fi
done | sort > "$subject_list"

subject_count="$(wc -l < "$subject_list" | tr -d ' ')"
if [[ "$subject_count" -eq 0 ]]; then
  echo "ERROR: no subjects with HCP structural MNINonLinear found under $HCP_STRUCTURAL_OUT" >&2
  exit 2
fi

last_index="$((subject_count - 1))"

echo "Subject list: $subject_list"
echo "Subject count: $subject_count"
echo "Array range: 0-${last_index}"

sbatch \
  --array="0-${last_index}" \
  --partition="${HYAK_PARTITION:?ERROR: HYAK_PARTITION must be set in the config}" \
  --time="${HCP_FUNCTIONAL_HYAK_TIME:-48:00:00}" \
  --output="${LOG_ROOT}/slurm/hcp-functional/hcp_functional_%A_%a.out" \
  --error="${LOG_ROOT}/slurm/hcp-functional/hcp_functional_%A_%a.err" \
  "${REPO_DIR}/scripts/submit_hcp_functional_hyak.sbatch" \
  "$CONFIG_ENV" \
  "$subject_list"
