#!/usr/bin/env bash
set -euo pipefail

# Download Flywheel DICOM sessions, optionally filtered by subject, date, and release session selection.
#
# Usage:
#   export FW_KEY='...'
#   ./download_data_from_flywheel_to_hyak.sh --config config/mri_preproc.env --list-only 1
#   ./download_data_from_flywheel_to_hyak.sh --sub-id 105 --list-only 0
#
# Notes:
#   - fw sync --include only filters file types, not dates.
#   - The script lists sessions for the selected subject (or project), optionally
#     filters them by timestamp, and always writes a CSV manifest after a
#     successful query. It then downloads each matching session's DICOM files.
#   - Subject IDs must match the Flywheel subject label exactly.
#   - Omit --sub-id to include all subjects; omit --start-date to include all dates.
#   - --config applies RELEASE_SESSION_LABELS and FLYWHEEL_SESSION_LABEL_MAP.
#   - Missing Slurm directories are excluded from Apptainer system binds so
#     downloads can run on login nodes without those directories.

usage() {
    cat <<'USAGE'
Usage: download_data_from_flywheel_to_hyak.sh [OPTIONS]

  --sub-id ID                  Select an exact Flywheel subject label.
  --config PATH                Read RELEASE_SESSION_LABELS from this config file.
  --start-date YYYY-MM-DD      Earliest session date; omit for all dates.
  --list-only 0|1             Write manifest only (default: 1); 0 downloads.
  --jobs COUNT                Concurrent downloads (default: 1).
  --manifest PATH             Manifest path (default: destination-derived path).
  --output-dir PATH           Hyak directory for downloaded data and manifests.
  --kopah-uri S3_URI          Kopah destination (default: KOPAH_SOURCE_DICOM_URI from config).
  --s3cfg PATH                s3cmd config containing Kopah credentials.
  --keep-local 0|1            Retain local downloaded data after a successful upload (default: 1).
  --container-output-dir PATH Mount point for --output-dir (default: /DATA_DIR).
  --image PATH                Apptainer image path.
  --project-path PATH         Flywheel project path (default: fang-lab/PROJECT_NAME from config).
  --fw-host HOST              Flywheel host for a token-only FW_KEY.
  -h, --help                  Show this help.

Required environment:
  FW_KEY                      Flywheel API key.

Without --sub-id, all subjects are queried. Without --start-date, all session
dates are included. With --config, RELEASE_SESSION_LABELS limits the query.
The script fails if any requested Flywheel session label is absent.
USAGE
}

set_defaults() {
    IMAGE="/gscratch/fang/resources/images/flywheel.sif"
    HOST_OUTPUT_DIR=""
    KOPAH_URI=""
    S3CFG=""
    KEEP_LOCAL="1"
    CONTAINER_OUTPUT_DIR="/DATA_DIR"
    PROJECT_PATH=""
    FW_HOST=""
    START_DATE=""
    LIST_ONLY="1"
    JOBS="1"
    MANIFEST=""
    TARGET_SUBJECT=""
    CONFIG_ENV=""
    FW_SESSION_LABELS=""
}

require_option_value() {
    local option="$1"
    local value="${2:-}"

    if [[ -z "${value}" || "${value}" == -* ]]; then
        echo "Error: ${option} requires a value." >&2
        exit 1
    fi
}

parse_arguments() {
    while (( $# > 0 )); do
        case "$1" in
            --sub-id)
                require_option_value "$1" "${2:-}"
                TARGET_SUBJECT="$2"
                shift 2
                ;;
            --config|--start-date|--list-only|--jobs|--manifest|--output-dir|--kopah-uri|--s3cfg|--keep-local|--container-output-dir|--image|--project-path|--fw-host)
                require_option_value "$1" "${2:-}"
                case "$1" in
                    --config) CONFIG_ENV="$2" ;;
                    --start-date) START_DATE="$2" ;;
                    --list-only) LIST_ONLY="$2" ;;
                    --jobs) JOBS="$2" ;;
                    --manifest) MANIFEST="$2" ;;
                    --output-dir) HOST_OUTPUT_DIR="$2" ;;
                    --kopah-uri) KOPAH_URI="$2" ;;
                    --s3cfg) S3CFG="$2" ;;
                    --keep-local) KEEP_LOCAL="$2" ;;
                    --container-output-dir) CONTAINER_OUTPUT_DIR="$2" ;;
                    --image) IMAGE="$2" ;;
                    --project-path) PROJECT_PATH="$2" ;;
                    --fw-host) FW_HOST="$2" ;;
                esac
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Error: Unknown argument: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

require_boolean() {
    local name="$1"
    local value="$2"

    if [[ "${value}" != "0" && "${value}" != "1" ]]; then
        echo "Error: ${name} must be 0 or 1." >&2
        exit 1
    fi
}

validate_configuration() {
    if [[ -z "${FW_KEY:-}" ]]; then
        echo "Error: FW_KEY is not set. Run: export FW_KEY='your_flywheel_api_key'" >&2
        exit 1
    fi

    require_boolean "LIST_ONLY" "${LIST_ONLY}"
    require_boolean "KEEP_LOCAL" "${KEEP_LOCAL}"
    if [[ "${KOPAH_URI}" != s3://* ]]; then
        echo "Error: KOPAH_URI must be an s3:// URI." >&2
        exit 1
    fi
    if [[ ! -r "${S3CFG}" ]]; then
        echo "Error: Kopah s3cmd configuration is not readable: ${S3CFG}" >&2
        exit 1
    fi
    if ! command -v s3cmd >/dev/null 2>&1; then
        echo "Error: s3cmd is required to upload to Kopah." >&2
        exit 1
    fi
}

build_apptainer_command() {
    apptainer_command=(apptainer exec)
    for slurm_path in /var/run/slurm /var/spool/slurmd; do
        if [[ ! -e "${slurm_path}" ]]; then
            echo "Skipping missing Slurm system bind: ${slurm_path}"
            apptainer_command+=(--no-mount "${slurm_path}")
        fi
    done
}

safe_filename_component() {
    printf '%s' "$1" | tr -cs 'A-Za-z0-9._-' '_'
}

build_default_manifest() {
    local project_name subject_scope date_scope session_scope

    project_name="$(safe_filename_component "${PROJECT_PATH##*/}")"
    subject_scope="$(safe_filename_component "${TARGET_SUBJECT:-all}")"
    date_scope="dates-all"
    if [[ -n "${START_DATE}" ]]; then
        date_scope="dates-after${START_DATE//-/}"
    fi
    session_scope="sessions-${RELEASE_LABEL:-all}"

    MANIFEST="${CONTAINER_OUTPUT_DIR}/flywheel_${project_name}_subject-${subject_scope}_${session_scope}_${date_scope}.csv"
}

resolve_release_sessions() {
    local bids_label mapping mapping_bids mapping_flywheel resolved
    [[ -n "${RELEASE_SESSION_LABELS:-}" ]] || return
    [[ -n "${RELEASE_LABEL:-}" ]] || { echo "Error: RELEASE_LABEL is required when RELEASE_SESSION_LABELS is set." >&2; exit 1; }
    for bids_label in ${RELEASE_SESSION_LABELS}; do
        [[ "$bids_label" =~ ^ses-[A-Za-z0-9]+([_-][A-Za-z0-9]+)*$ ]] || {
            echo "Error: invalid BIDS session label: $bids_label (expected ses-*)" >&2
            exit 1
        }
        resolved="$bids_label"
        for mapping in ${FLYWHEEL_SESSION_LABEL_MAP:-}; do
            mapping_bids="${mapping%%=*}"
            mapping_flywheel="${mapping#*=}"
            [[ "$mapping" == *=* && -n "$mapping_flywheel" ]] || {
                echo "Error: invalid FLYWHEEL_SESSION_LABEL_MAP entry: $mapping" >&2
                exit 1
            }
            [[ "$mapping_bids" == "$bids_label" ]] && resolved="$mapping_flywheel"
        done
        FW_SESSION_LABELS+="${FW_SESSION_LABELS:+$'\n'}${resolved}"
    done
}

set_defaults
parse_arguments "$@"

if [[ -n "${CONFIG_ENV}" ]]; then
    [[ -r "${CONFIG_ENV}" ]] || { echo "Error: config is not readable: ${CONFIG_ENV}" >&2; exit 1; }
    # shellcheck source=/dev/null
    source "${CONFIG_ENV}"
fi
HOST_OUTPUT_DIR="${HOST_OUTPUT_DIR:-${SCRUBBED_PROJECT_DIR:?ERROR: SCRUBBED_PROJECT_DIR must be set in the config}/sourcedata/dicom}"
KOPAH_URI="${KOPAH_URI:-${KOPAH_SOURCE_DICOM_URI:?ERROR: KOPAH_SOURCE_DICOM_URI must be set in the config}}"
S3CFG="${S3CFG:-${KOPAH_S3CFG:?ERROR: KOPAH_S3CFG must be set in the config}}"
PROJECT_PATH="${PROJECT_PATH:-fang-lab/${PROJECT_NAME:?ERROR: PROJECT_NAME must be set in the config}}"
resolve_release_sessions

if [[ -z "${MANIFEST}" ]]; then
    build_default_manifest
fi

validate_configuration
mkdir -p "${HOST_OUTPUT_DIR}"
build_apptainer_command

"${apptainer_command[@]}" \
    --env FW_KEY="${FW_KEY}" \
    --env FW_HOST="${FW_HOST}" \
    --env START_DATE="${START_DATE}" \
    --env LIST_ONLY="${LIST_ONLY}" \
    --env MANIFEST="${MANIFEST}" \
    --env PROJECT_PATH="${PROJECT_PATH}" \
    --env CONTAINER_OUTPUT_DIR="${CONTAINER_OUTPUT_DIR}" \
    --env JOBS="${JOBS}" \
    --env TARGET_SUBJECT="${TARGET_SUBJECT}" \
    --env FW_SESSION_LABELS="${FW_SESSION_LABELS}" \
    -B "${HOST_OUTPUT_DIR}:${CONTAINER_OUTPUT_DIR}" \
    "${IMAGE}" \
    bash -s <<'CONTAINER_SCRIPT'
set -euo pipefail

export PYTHONNOUSERSITE=1

normalize_flywheel_key() {
    FW_KEY="$(printf '%s' "${FW_KEY}" | tr -d '[:space:]')"
    FW_KEY="${FW_KEY#https://}"
    FW_KEY="${FW_KEY#http://}"

    if [[ "${FW_KEY}" != *:* ]]; then
        if [[ -z "${FW_HOST:-}" ]]; then
            cat >&2 <<MSG
Error: FW_KEY is not in Flywheel SDK format.

Set either:
  export FW_KEY="uw-chn.flywheel.io:YOUR_API_KEY"

or, if you only copied the token portion, pass --fw-host uw-chn.flywheel.io
to this script and set:
  export FW_KEY="YOUR_API_KEY"
MSG
            exit 1
        fi

        FW_HOST="$(printf '%s' "${FW_HOST}" | tr -d '[:space:]')"
        FW_HOST="${FW_HOST#https://}"
        FW_HOST="${FW_HOST#http://}"
        FW_HOST="${FW_HOST%%/*}"
        FW_KEY="${FW_HOST}:${FW_KEY}"
    fi

    export FW_KEY
}

normalize_flywheel_key

check_flywheel_sdk() {
    python3 - <<'PY'
import sys

try:
    import flywheel
except Exception as exc:
    print(f"Flywheel Python SDK import failed: {exc}", file=sys.stderr)
    raise SystemExit(1)

if not hasattr(flywheel, "Client"):
    print(
        "Imported a flywheel module without flywheel.Client. "
        "This is usually the wrong package or an old SDK.",
        file=sys.stderr,
    )
    print(f"flywheel module path: {getattr(flywheel, '__file__', '<unknown>')}", file=sys.stderr)
    print(f"flywheel version: {getattr(flywheel, '__version__', '<unknown>')}", file=sys.stderr)
    raise SystemExit(1)
PY
}

if ! check_flywheel_sdk; then
    cat >&2 <<MSG
Error: The Flywheel Python SDK is not installed or does not expose flywheel.Client in this Apptainer image.

The fw CLI can download data, but it cannot filter sessions by timestamp.
Install a compatible flywheel-sdk in the Apptainer image before running this script.
MSG
    exit 1
fi

python3 - "$START_DATE" "$MANIFEST" "$PROJECT_PATH" "$TARGET_SUBJECT" <<'PY'
import csv
from datetime import date, datetime
import os
import sys

import flywheel

if not hasattr(flywheel, "Client"):
    raise RuntimeError(
        "Imported flywheel module does not expose Client. "
        f"module={getattr(flywheel, '__file__', '<unknown>')} "
        f"version={getattr(flywheel, '__version__', '<unknown>')}"
    )

start_date, manifest, project_path, target_subject = sys.argv[1:5]
start_day = date.fromisoformat(start_date) if start_date else None
requested_session_labels = {label for label in os.environ.get("FW_SESSION_LABELS", "").splitlines() if label}

fw = flywheel.Client(os.environ["FW_KEY"])
project = fw.lookup(project_path)


def timestamp_date(value):
    if value is None:
        return None
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    text = str(value)
    if len(text) >= 10:
        return date.fromisoformat(text[:10])
    return None

rows = []
matched_session_labels = set()
# Fetch target subject directly if supplied, otherwise iterate whole project
if target_subject:
    subject_path = f"{project_path}/{target_subject}"
    try:
        subject_obj = fw.lookup(subject_path)
        subject_sessions = list(subject_obj.sessions.iter_find())
    except Exception as exc:
        raise SystemExit(f"Error: Could not lookup subject path '{subject_path}': {exc}")

    for session in subject_sessions:
        session_day = timestamp_date(getattr(session, "timestamp", None))
        if start_day is not None and (session_day is None or session_day < start_day):
            continue

        full_session = fw.get(session.id)
        flywheel_label = getattr(full_session, "label", "")
        if requested_session_labels and flywheel_label not in requested_session_labels:
            continue
        matched_session_labels.add(flywheel_label)
        timestamp = getattr(full_session, "timestamp", "") or ""
        rows.append(
            {
                "subject_label": target_subject,
                "session_label": getattr(full_session, "label", ""),
                "session_id": full_session.id,
                "timestamp": str(timestamp),
                "download_path": (
                    f"{project_path}/"
                    f"{target_subject}/"
                    f"{getattr(full_session, 'label', '')}"
                ),
            }
        )
else:
    for session in project.sessions.iter_find():
        session_day = timestamp_date(getattr(session, "timestamp", None))
        if start_day is not None and (session_day is None or session_day < start_day):
            continue

        full_session = fw.get(session.id)
        flywheel_label = getattr(full_session, "label", "")
        if requested_session_labels and flywheel_label not in requested_session_labels:
            continue
        matched_session_labels.add(flywheel_label)
        subject_id = full_session.parents.subject
        subject = fw.get(subject_id) if subject_id else None
        subj_label = getattr(subject, "label", "") if subject else ""
        timestamp = getattr(full_session, "timestamp", "") or ""

        rows.append(
            {
                "subject_label": subj_label,
                "session_label": getattr(full_session, "label", ""),
                "session_id": full_session.id,
                "timestamp": str(timestamp),
                "download_path": (
                    f"{project_path}/"
                    f"{subj_label}/"
                    f"{getattr(full_session, 'label', '')}"
                ),
            }
        )

rows.sort(key=lambda row: (row["timestamp"], row["subject_label"], row["session_label"]))
missing_session_labels = requested_session_labels - matched_session_labels
if missing_session_labels:
    raise SystemExit("Requested Flywheel session labels were not found: " + ", ".join(sorted(missing_session_labels)))
if not rows:
    raise SystemExit("No Flywheel sessions matched the requested selection")
os.makedirs(os.path.dirname(manifest), exist_ok=True)

with open(manifest, "w", newline="") as f:
    writer = csv.DictWriter(
        f,
        fieldnames=[
            "subject_label",
            "session_label",
            "session_id",
            "timestamp",
            "download_path",
        ],
    )
    writer.writeheader()
    writer.writerows(rows)

print(f"Wrote {len(rows)} sessions to {manifest}")
PY

echo "Manifest:"
echo "  ${MANIFEST}"

if [[ "${LIST_ONLY}" == "1" ]]; then
    echo "LIST_ONLY=1, so no data were downloaded."
    echo "Review the manifest, then rerun with LIST_ONLY=0 to download."
    exit 0
fi

download_one_file() {
        acquisition_id="$1"
        file_name="$2"
        out_path="$3"
        expected_size="$4"
        rel_path="$5"

        python3 - "$acquisition_id" "$file_name" "$out_path" "$expected_size" "$rel_path" <<'PY'
import os
import sys

import flywheel

if not hasattr(flywheel, "Client"):
    raise RuntimeError(
        "Imported flywheel module does not expose Client. "
        f"module={getattr(flywheel, '__file__', '<unknown>')} "
        f"version={getattr(flywheel, '__version__', '<unknown>')}"
    )

acquisition_id, file_name, out_path, expected_size, rel_path = sys.argv[1:6]
expected_size = int(expected_size) if expected_size else None

if (
    expected_size is not None
    and os.path.exists(out_path)
    and os.path.getsize(out_path) == expected_size
):
    print(f"exists: {rel_path}")
    raise SystemExit(0)

if os.path.exists(out_path):
    os.remove(out_path)

os.makedirs(os.path.dirname(out_path), exist_ok=True)
print(f"downloading: {rel_path}", flush=True)

fw = flywheel.Client(os.environ["FW_KEY"])
acquisition = fw.get(acquisition_id)
acquisition.download_file(file_name, out_path)

if expected_size is not None and os.path.getsize(out_path) != expected_size:
    raise RuntimeError(
        f"Downloaded size mismatch for {out_path}: "
        f"expected {expected_size}, got {os.path.getsize(out_path)}"
    )
PY
    }

    export -f download_one_file
    export FW_KEY

    python3 - "$MANIFEST" "$CONTAINER_OUTPUT_DIR" <<'PY' | xargs -0 -n 5 -P "${JOBS}" bash -c 'download_one_file "$1" "$2" "$3" "$4" "$5"' bash
import csv
import os
import re
import sys

import flywheel

if not hasattr(flywheel, "Client"):
    raise RuntimeError(
        "Imported flywheel module does not expose Client. "
        f"module={getattr(flywheel, '__file__', '<unknown>')} "
        f"version={getattr(flywheel, '__version__', '<unknown>')}"
    )

manifest, bind_dest = sys.argv[1:3]
fw = flywheel.Client(os.environ["FW_KEY"])


def safe_name(value):
    value = (value or "").strip() or "unknown"
    return re.sub(r"[^A-Za-z0-9._-]+", "_", value)


def file_size(file_obj):
    value = getattr(file_obj, "size", None)
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


with open(manifest, newline="") as f:
    rows = list(csv.DictReader(f))

for row in rows:
    subject = safe_name(row["subject_label"])
    session_label = safe_name(row["session_label"])
    session = fw.get(row["session_id"])
    session_dir = os.path.join(bind_dest, subject, session_label)
    os.makedirs(session_dir, exist_ok=True)

    acquisitions = list(session.acquisitions.iter_find())
    for acq_ref in acquisitions:
        acquisition = fw.get(acq_ref.id)
        acq_label = safe_name(getattr(acquisition, "label", "acquisition"))
        acq_dir = os.path.join(session_dir, acq_label)

        for acq_file in acquisition.files:
            if getattr(acq_file, "type", None) != "dicom":
                continue

            file_name = os.path.basename(acq_file.name)
            out_path = os.path.join(acq_dir, file_name)
            expected_size = file_size(acq_file)
            rel_path = f"{subject}/{session_label}/{acq_label}/{file_name}"
            values = [
                acquisition.id,
                acq_file.name,
                out_path,
                "" if expected_size is None else str(expected_size),
                rel_path,
            ]
            for value in values:
                sys.stdout.buffer.write(value.encode())
                sys.stdout.buffer.write(b"\0")
PY
echo "download successfully"

CONTAINER_SCRIPT

echo "Uploading staged DICOM and manifest to Kopah: ${KOPAH_URI}"
s3cmd --config="${S3CFG}" sync "${HOST_OUTPUT_DIR%/}/" "${KOPAH_URI%/}/"

if [[ "${KEEP_LOCAL}" == "0" ]]; then
    echo "Removing successfully uploaded local staging directory: ${HOST_OUTPUT_DIR}"
    rm -rf "${HOST_OUTPUT_DIR}"
fi
