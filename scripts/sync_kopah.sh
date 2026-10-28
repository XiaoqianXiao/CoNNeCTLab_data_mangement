#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/sync_kopah.sh pull S3_URI LOCAL_DIRECTORY [--s3cfg PATH]
  scripts/sync_kopah.sh push LOCAL_DIRECTORY S3_URI [--s3cfg PATH]

Synchronize a directory between Kopah S3 and local Hyak storage. Credentials
remain in the s3cmd configuration file; do not put them in this script or a
project environment file. A push is verified with a dry-run synchronization;
the command fails if any local files would still need uploading.
USAGE
}

S3CFG="/mmfs1/home/xxqian/.s3cfg"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 3 ]]; then
  usage >&2
  exit 2
fi

ACTION="$1"
SOURCE="$2"
DESTINATION="$3"
shift 3

while (( $# > 0 )); do
  case "$1" in
    --s3cfg)
      [[ -n "${2:-}" ]] || { echo "ERROR: --s3cfg requires a path." >&2; exit 2; }
      S3CFG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v s3cmd >/dev/null 2>&1; then
  echo "ERROR: s3cmd is required but was not found on PATH." >&2
  exit 127
fi

if [[ ! -r "$S3CFG" ]]; then
  echo "ERROR: Kopah s3cmd configuration is not readable: $S3CFG" >&2
  exit 2
fi

case "$ACTION" in
  pull)
    [[ "$SOURCE" == s3://* ]] || { echo "ERROR: pull source must be an s3:// URI." >&2; exit 2; }
    mkdir -p "$DESTINATION"
    echo "Pulling $SOURCE -> $DESTINATION"
    s3cmd --config="$S3CFG" sync "${SOURCE%/}/" "${DESTINATION%/}/"
    ;;
  push)
    [[ "$DESTINATION" == s3://* ]] || { echo "ERROR: push destination must be an s3:// URI." >&2; exit 2; }
    [[ -d "$SOURCE" ]] || { echo "ERROR: local source directory does not exist: $SOURCE" >&2; exit 2; }
    echo "Pushing $SOURCE -> $DESTINATION"
    s3cmd --config="$S3CFG" sync "${SOURCE%/}/" "${DESTINATION%/}/"
    echo "Verifying Kopah upload: $SOURCE -> $DESTINATION"
    verification_output="$(s3cmd --config="$S3CFG" sync --dry-run "${SOURCE%/}/" "${DESTINATION%/}/")" || {
      echo "ERROR: unable to verify Kopah upload." >&2
      exit 2
    }
    if [[ -n "$verification_output" ]]; then
      printf '%s\n' "$verification_output"
    fi
    if printf '%s\n' "$verification_output" | grep -Eq '(^|[[:space:]])(upload|copy):'; then
      echo "ERROR: Kopah verification found files that were not synchronized; preserving local output." >&2
      exit 2
    fi
    ;;
  *)
    echo "ERROR: action must be pull or push." >&2
    usage >&2
    exit 2
    ;;
esac
