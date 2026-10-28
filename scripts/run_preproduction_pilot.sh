#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/run_preproduction_pilot.sh CONFIG_ENV

Runs the pre-production checks required before freezing cohort-wide fMRIPrep:
1. BIDS validation
2. AP/PA SDC metadata audit
3. fMRIPrep pilot run using the frozen canonical settings
4. Expected-output check
5. Release manifest generation
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  exit 0
fi

CONFIG_ENV="$1"
# shellcheck source=/dev/null
source "$CONFIG_ENV"

mkdir -p "$LOG_DIR" "$PROVENANCE_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
timestamp="$(date +%Y%m%d_%H%M%S)"
subject_list="${LOG_DIR}/fmriprep_pilot_subjects_${timestamp}.txt"
session_manifest="${LOG_DIR}/fmriprep_pilot_multisession_manifest_${timestamp}.csv"
sdc_report="${LOG_DIR}/sdc_metadata_audit_${timestamp}.csv"
output_report="${LOG_DIR}/fmriprep_output_check_${timestamp}.csv"
manifest="${PROVENANCE_DIR}/preproduction_manifest_${timestamp}.json"

"${SCRIPT_DIR}/run_python_hyak.sh" \
  "$CONFIG_ENV" \
  "${SCRIPT_DIR}/make_multisession_manifest.py" \
  "$BIDS_DIR" \
  --manifest "$session_manifest" \
  --subject-list "$subject_list"

"${SCRIPT_DIR}/run_bids_validator.sh" "$CONFIG_ENV"

"${SCRIPT_DIR}/run_python_hyak.sh" \
  "$CONFIG_ENV" \
  "${SCRIPT_DIR}/audit_sdc_metadata.py" \
  "$BIDS_DIR" \
  --output "$sdc_report"

"${SCRIPT_DIR}/run_fmriprep.sh" "$CONFIG_ENV"

participant_args=()
if [[ -n "${PARTICIPANT_LABELS:-}" ]]; then
  # shellcheck disable=SC2206
  participant_array=($PARTICIPANT_LABELS)
  participant_args=(--participant-label "${participant_array[@]}")
fi

"${SCRIPT_DIR}/run_python_hyak.sh" \
  "$CONFIG_ENV" \
  "${SCRIPT_DIR}/check_fmriprep_outputs.py" \
  --fmriprep-dir "$FMRIPREP_OUT" \
  --freesurfer-dir "$FS_SUBJECTS_DIR" \
  "${participant_args[@]}" \
  --output "$output_report"

latest_bids_log="$(ls -t "${LOG_DIR}"/bids-validator_*.log | head -n 1)"
latest_command_log="$(ls -t "${LOG_DIR}"/fmriprep_command_*.txt | head -n 1)"

"${SCRIPT_DIR}/run_python_hyak.sh" \
  "$CONFIG_ENV" \
  "${SCRIPT_DIR}/freeze_release_manifest.py" \
  --config "$CONFIG_ENV" \
  --command-log "$latest_command_log" \
  --bids-validator-log "$latest_bids_log" \
  --sdc-audit "$sdc_report" \
  --output "$manifest" \
  --extra-file "$session_manifest" \
  --extra-file "${SCRIPT_DIR}/run_fmriprep.sh" \
  --extra-file "${SCRIPT_DIR}/run_python_hyak.sh" \
  --extra-file "${SCRIPT_DIR}/make_multisession_manifest.py" \
  --extra-file "${SCRIPT_DIR}/audit_sdc_metadata.py" \
  --extra-file "${SCRIPT_DIR}/check_fmriprep_outputs.py"

echo "Pre-production pilot complete."
echo "Session manifest: $session_manifest"
echo "SDC report: $sdc_report"
echo "Output report: $output_report"
echo "Manifest: $manifest"
