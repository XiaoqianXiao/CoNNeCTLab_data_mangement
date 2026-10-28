#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: scripts/publish_fmriprep_subject.sh CONFIG_ENV SUBJECT" >&2
  exit 2
fi

config_env="$1"
subject="$2"
# shellcheck source=/dev/null
source "$config_env"

[[ "$subject" == sub-* ]] || { echo "ERROR: SUBJECT must use the sub-* label: $subject" >&2; exit 2; }
[[ "${FMRIPREP_PUBLISH_TO_KOPAH:-0}" == "1" ]] || exit 0
for required in KOPAH_S3CFG KOPAH_DERIVATIVES_URI FMRIPREP_OUT FS_SUBJECTS_DIR PROVENANCE_DIR; do
  [[ -n "${!required:-}" ]] || { echo "ERROR: $required is required for Kopah publishing" >&2; exit 2; }
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fmriprep_subject_dir="${FMRIPREP_OUT}/${subject}"
[[ -d "$fmriprep_subject_dir" ]] || { echo "ERROR: missing fMRIPrep output: $fmriprep_subject_dir" >&2; exit 2; }
provenance_dir="${PROVENANCE_DIR}/freesurfer_subject_map/${subject}"
provenance_file="${provenance_dir}/mapping.json"
freesurfer_subject_dir="$("${script_dir}/run_python_hyak.sh" "$config_env" "${script_dir}/freesurfer_subject.py" \
  --subjects-dir "$FS_SUBJECTS_DIR" --participant "$subject" --provenance-output "$provenance_file")"

remote_release_prefix="${KOPAH_DERIVATIVES_URI%/}"
"${script_dir}/sync_kopah.sh" push "$fmriprep_subject_dir" "${remote_release_prefix}/fmriprep/${subject}" --s3cfg "$KOPAH_S3CFG"
echo "Publishing FreeSurfer source $(basename "$freesurfer_subject_dir") as canonical ${subject}"
"${script_dir}/sync_kopah.sh" push "$freesurfer_subject_dir" "${remote_release_prefix}/freesurfer/${subject}" --s3cfg "$KOPAH_S3CFG"
"${script_dir}/sync_kopah.sh" push "$provenance_dir" "${remote_release_prefix}/qc/provenance/freesurfer_subject_map/${subject}" --s3cfg "$KOPAH_S3CFG"

if [[ "${FMRIPREP_REMOVE_LOCAL_OUTPUT:-0}" == "1" ]]; then
  echo "Removing verified local fMRIPrep and FreeSurfer outputs for ${subject}"
  rm -rf "${FMRIPREP_OUT:?}/${subject}" "$freesurfer_subject_dir"
fi
