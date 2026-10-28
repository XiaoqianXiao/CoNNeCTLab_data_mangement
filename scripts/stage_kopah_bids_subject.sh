#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 KOPAH_BIDS_URI LOCAL_BIDS_DIR SUBJECT S3CFG" >&2
  exit 2
fi

KOPAH_BIDS_URI="$1"
LOCAL_BIDS_DIR="$2"
SUBJECT="$3"
S3CFG="$4"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ "$KOPAH_BIDS_URI" == s3://* ]] || { echo "ERROR: KOPAH_BIDS_URI must be an s3:// URI." >&2; exit 2; }
[[ "$SUBJECT" == sub-* ]] || { echo "ERROR: subject must use the sub-* label." >&2; exit 2; }
[[ ! -e "${LOCAL_BIDS_DIR}/${SUBJECT}" ]] || { echo "ERROR: staging destination already exists: ${LOCAL_BIDS_DIR}/${SUBJECT}" >&2; exit 2; }

"${SCRIPT_DIR}/sync_kopah.sh" pull "${KOPAH_BIDS_URI%/}/${SUBJECT}" "${LOCAL_BIDS_DIR}/${SUBJECT}" --s3cfg "$S3CFG"
mkdir -p "$LOCAL_BIDS_DIR"
s3cmd --config="$S3CFG" get "${KOPAH_BIDS_URI%/}/dataset_description.json" "${LOCAL_BIDS_DIR}/dataset_description.json"
