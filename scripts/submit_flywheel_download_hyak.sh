#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/submit_flywheel_download_hyak.sh CONFIG_ENV SUBJECT [SUBJECT ...]

Submit one Hyak compute-node job per exact Flywheel subject label. The wrapper
uses HYAK_ACCOUNT and the FLYWHEEL_DOWNLOAD_* settings in CONFIG_ENV, exports
FW_KEY to each job, and delegates the download to
scripts/download_data_from_flywheel_to_hyak.sh.

Required environment:
  FW_KEY  Flywheel API key.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 2 ]]; then
  usage
  exit 0
fi

config_env="$1"
shift
subjects=("$@")
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

[[ "$config_env" = /* ]] || config_env="$repo_dir/$config_env"
[[ -r "$config_env" ]] || { echo "ERROR: config is not readable: $config_env" >&2; exit 2; }
[[ -n "${FW_KEY:-}" ]] || { echo "ERROR: FW_KEY is not set." >&2; exit 2; }

# shellcheck source=/dev/null
source "$config_env"

account="${HYAK_ACCOUNT:?ERROR: HYAK_ACCOUNT must be set in the config}"
partition="${HYAK_PARTITION:?ERROR: HYAK_PARTITION must be set in the config}"
time_limit="${FLYWHEEL_DOWNLOAD_TIME:-04:00:00}"
cpus="${FLYWHEEL_DOWNLOAD_CPUS:-4}"
memory="${FLYWHEEL_DOWNLOAD_MEM:-8G}"
download_jobs="${FLYWHEEL_DOWNLOAD_JOBS:-$cpus}"
log_dir="${FLYWHEEL_DOWNLOAD_LOG_DIR:-${LOG_ROOT:-${SCRUBBED_PROJECT_DIR}/logs}/flywheel}"

[[ "$cpus" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: FLYWHEEL_DOWNLOAD_CPUS must be a positive integer." >&2; exit 2; }
[[ "$download_jobs" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: FLYWHEEL_DOWNLOAD_JOBS must be a positive integer." >&2; exit 2; }

mkdir -p "$log_dir"

for subject in "${subjects[@]}"; do
  [[ -n "$subject" ]] || { echo "ERROR: subject labels must not be empty." >&2; exit 2; }
  echo "Submitting Flywheel download for subject $subject to $partition ($account)"
  sbatch \
    --job-name="flywheel-${subject}" \
    --account="$account" \
    --partition="$partition" \
    --time="$time_limit" \
    --cpus-per-task="$cpus" \
    --mem="$memory" \
    --output="$log_dir/flywheel_${subject}_%j.out" \
    --export=ALL \
    "$repo_dir/scripts/download_data_from_flywheel_to_hyak.sh" \
      --config "$config_env" \
      --sub-id "$subject" \
      --list-only 0 \
      --jobs "$download_jobs"
done
