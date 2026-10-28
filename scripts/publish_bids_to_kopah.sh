#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/publish_bids_to_kopah.sh CONFIG_ENV

Synchronize the completed local BIDS dataset to Kopah without removing the
local copy. Run this after the relevant Heudiconv conversions have completed
and before submitting preprocessing jobs that stage BIDS data from Kopah.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
    usage
    exit 0
fi

config_env="$1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${config_env}" != /* ]]; then
    config_env="$(pwd)/${config_env}"
fi

if [[ ! -r "${config_env}" ]]; then
    echo "ERROR: configuration file is not readable: ${config_env}" >&2
    exit 2
fi

# shellcheck source=/dev/null
source "${config_env}"

for required_var in BIDS_DIR KOPAH_BIDS_URI KOPAH_S3CFG; do
    if [[ -z "${!required_var:-}" ]]; then
        echo "ERROR: ${required_var} must be set in ${config_env}." >&2
        exit 2
    fi
done

if [[ ! -d "${BIDS_DIR}" ]]; then
    echo "ERROR: local BIDS directory does not exist: ${BIDS_DIR}" >&2
    exit 2
fi

echo "Publishing local BIDS dataset: ${BIDS_DIR} -> ${KOPAH_BIDS_URI}"
"${script_dir}/sync_kopah.sh" push "${BIDS_DIR}" "${KOPAH_BIDS_URI}" --s3cfg "${KOPAH_S3CFG}"
