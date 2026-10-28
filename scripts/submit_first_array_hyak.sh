#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  echo "Usage: scripts/submit_first_array_hyak.sh CONFIG_ENV"
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
mkdir -p "${LOG_ROOT:-/gscratch/scrubbed/fanglab/xiaoqian/IFOCUS/logs}/slurm/first" "$LOG_DIR"

timestamp="$(date +%Y%m%d_%H%M%S)"
subject_list="${LOG_DIR}/first_subjects_${timestamp}.txt"

if [[ "${FIRST_STAGE_FROM_KOPAH:-0}" == "1" ]]; then
  for required_var in KOPAH_S3CFG KOPAH_DERIVATIVES_URI; do
    [[ -n "${!required_var:-}" ]] || { echo "ERROR: $required_var is required when FIRST_STAGE_FROM_KOPAH=1." >&2; exit 2; }
  done
  command -v s3cmd >/dev/null 2>&1 || { echo "ERROR: s3cmd is required when FIRST_STAGE_FROM_KOPAH=1." >&2; exit 127; }
  remote_fmriprep_prefix="${KOPAH_DERIVATIVES_URI%/}/fmriprep"
  s3cmd --config="$KOPAH_S3CFG" ls --recursive "${remote_fmriprep_prefix}/" | \
    awk -v prefix="${remote_fmriprep_prefix}/" '{ key = $NF; if (index(key, prefix) == 1) { key = substr(key, length(prefix) + 1); split(key, parts, "/"); if (parts[1] ~ /^sub-/ && parts[2] == "anat" && key ~ /_desc-preproc_T1w\.nii\.gz$/ && key !~ /_space-/) print parts[1] } }' | \
    sort -u > "$subject_list"
else
  shopt -s nullglob
  shared_t1w_candidates=("$FMRIPREP_OUT"/sub-*/anat/*desc-preproc_T1w.nii.gz)
  for shared_t1w in "${shared_t1w_candidates[@]}"; do
    [[ "$(basename "$shared_t1w")" != *"_space-"* ]] || continue
    basename "$(dirname "$(dirname "$shared_t1w")")"
  done | sort -u > "$subject_list"
fi
subject_count="$(wc -l < "$subject_list" | tr -d ' ')"
if [[ "$subject_count" -eq 0 ]]; then
  echo "ERROR: no fMRIPrep sub-* directories found in the configured FIRST input source." >&2
  exit 2
fi

last_index="$((subject_count - 1))"

echo "Subject list: $subject_list"
echo "Subject count: $subject_count"
echo "Array range: 0-${last_index}"

sbatch \
  --array="0-${last_index}" \
  --partition="${HYAK_PARTITION:?ERROR: HYAK_PARTITION must be set in the config}" \
  --time="${FIRST_HYAK_TIME:-12:00:00}" \
  "${REPO_DIR}/scripts/submit_first_hyak.sbatch" \
  "$CONFIG_ENV" \
  "$subject_list"
