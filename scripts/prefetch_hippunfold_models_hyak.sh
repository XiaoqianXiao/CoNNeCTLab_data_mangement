#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/prefetch_hippunfold_models_hyak.sh CONFIG_ENV

Populates the shared HippUnfold model cache before array jobs.
Run this from an internet-enabled Hyak login/data-transfer context, not inside
the HippUnfold SLURM array.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -ne 1 ]]; then
  usage
  exit 0
fi

CONFIG_ENV="$1"
# shellcheck source=/dev/null
source "$CONFIG_ENV"

HIPPUNFOLD_OUT="${HIPPUNFOLD_OUT:-${DERIVATIVES_DIR}/hippunfold}"
HIPPUNFOLD_WORK="${HIPPUNFOLD_WORK:-${WORK_ROOT:-${SCRUBBED_PROJECT_DIR}/scratch}/hippunfold}"
HIPPUNFOLD_CACHE_DIR="${HIPPUNFOLD_CACHE_DIR:-${SCRUBBED_PROJECT_DIR}/cache/hippunfold}"
HIPPUNFOLD_MODALITY="${HIPPUNFOLD_MODALITY:-T1w}"
HIPPUNFOLD_TEMPLATE="${HIPPUNFOLD_TEMPLATE:-CITI168}"
HIPPUNFOLD_INJECT_TEMPLATE="${HIPPUNFOLD_INJECT_TEMPLATE:-upenn}"
HIPPUNFOLD_BUILTIN_ATLAS="${HIPPUNFOLD_BUILTIN_ATLAS:-multihist7}"

required_vars=(DERIVATIVES_DIR HIPPUNFOLD_OUT HIPPUNFOLD_WORK HIPPUNFOLD_CACHE_DIR HIPPUNFOLD_MODALITY HIPPUNFOLD_TEMPLATE HIPPUNFOLD_INJECT_TEMPLATE HIPPUNFOLD_BUILTIN_ATLAS)
for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "ERROR: $var_name is not set in $CONFIG_ENV" >&2
    exit 2
  fi
done

hippunfold_model_file() {
  case "$1" in
    T1w) echo "trained_model.3d_fullres.Task101_hcp1200_T1w.nnUNetTrainerV2.model_best.tar" ;;
    T2w) echo "trained_model.3d_fullres.Task102_hcp1200_T2w.nnUNetTrainerV2.model_best.tar" ;;
    b1000|b1000crop) echo "trained_model.3d_fullres.Task110_hcp1200_b1000crop.nnUNetTrainerV2.model_best.tar" ;;
    *) echo "" ;;
  esac
}

hippunfold_model_url() {
  case "$1" in
    T1w) echo "https://zenodo.org/record/4508747/files/trained_model.3d_fullres.Task101_hcp1200_T1w.nnUNetTrainerV2.model_best.tar" ;;
    T2w) echo "https://zenodo.org/record/4508747/files/trained_model.3d_fullres.Task102_hcp1200_T2w.nnUNetTrainerV2.model_best.tar" ;;
    b1000|b1000crop) echo "https://zenodo.org/record/5732291/files/trained_model.3d_fullres.Task110_hcp1200_b1000crop.nnUNetTrainerV2.model_best.tar" ;;
    *) echo "" ;;
  esac
}

hippunfold_atlas_url() {
  case "$1" in
    multihist7) echo "https://zenodo.org/records/18451323/files/tpl-multihist7_flatdir.zip" ;;
    *) echo "" ;;
  esac
}

hippunfold_template_url() {
  case "$1" in
    CITI168) echo "https://files.ca-1.osf.io/v1/resources/v8acf/providers/osfstorage/65395bf0282745121fb86a93/?zip=" ;;
    upenn) echo "https://files.ca-1.osf.io/v1/resources/v8acf/providers/osfstorage/65395c1613d27b122a94ca09/?zip=" ;;
    dHCP) echo "https://files.ca-1.osf.io/v1/resources/v8acf/providers/osfstorage/65395bff13d27b123094c9b4/?zip=" ;;
    MBMv3) echo "https://files.ca-1.osf.io/v1/resources/v8acf/providers/osfstorage/65395c0e8a28b11240ffc6e9/?zip=" ;;
    CIVM) echo "https://files.ca-1.osf.io/v1/resources/v8acf/providers/osfstorage/65395bf62827451220b86e24/?zip=" ;;
    ABAv3) echo "https://files.ca-1.osf.io/v1/resources/v8acf/providers/osfstorage/6668855b6b6c8e2cc704ca97/?zip=" ;;
    *) echo "" ;;
  esac
}

download_file() {
  local url="$1"
  local output="$2"
  local tmp_output="${output}.tmp.$$"
  if command -v curl >/dev/null 2>&1; then
    curl -fL "$url" -o "$tmp_output"
  elif command -v wget >/dev/null 2>&1; then
    wget "$url" -O "$tmp_output"
  else
    echo "ERROR: neither curl nor wget is available for download." >&2
    exit 127
  fi
  mv "$tmp_output" "$output"
}

download_zip_dir() {
  local url="$1"
  local out_dir="$2"
  if [[ -d "$out_dir" && -n "$(find "$out_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    touch "${out_dir}/.snakemake_timestamp"
    echo "Resource already exists: $out_dir"
    return
  fi
  mkdir -p "$out_dir"
  local zip_file="${out_dir}.zip.tmp.$$"
  download_file "$url" "$zip_file"
  unzip -q "$zip_file" -d "$out_dir"
  rm -f "$zip_file"
  touch "${out_dir}/.snakemake_timestamp"
}

copy_resource_dir() {
  local src_dir="$1"
  local dst_dir="$2"
  if [[ -d "$dst_dir" && -n "$(find "$dst_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    touch "${dst_dir}/.snakemake_timestamp"
    echo "Resource already exists: $dst_dir"
    return
  fi
  mkdir -p "$dst_dir"
  cp -a "${src_dir}/." "$dst_dir/"
  touch "${dst_dir}/.snakemake_timestamp"
}

mkdir -p "$HIPPUNFOLD_OUT" "$HIPPUNFOLD_WORK" "${HIPPUNFOLD_CACHE_DIR}/model" "${HIPPUNFOLD_CACHE_DIR}/atlas" "${HIPPUNFOLD_CACHE_DIR}/atlases" "${HIPPUNFOLD_CACHE_DIR}/atlases_dl" "${HIPPUNFOLD_CACHE_DIR}/template"
snakebids_marker="${HIPPUNFOLD_OUT}/.snakebids"
tmp_marker="${snakebids_marker}.tmp.$$"
printf '%s\n' '{"mode":"bidsapp"}' > "$tmp_marker"
mv "$tmp_marker" "$snakebids_marker"

echo "HippUnfold model cache: $HIPPUNFOLD_CACHE_DIR"
echo "Prefetching modality: $HIPPUNFOLD_MODALITY"
required_model="${HIPPUNFOLD_REQUIRED_MODEL:-$(hippunfold_model_file "$HIPPUNFOLD_MODALITY")}"
model_url="$(hippunfold_model_url "$HIPPUNFOLD_MODALITY")"
if [[ -z "$required_model" || -z "$model_url" ]]; then
  echo "ERROR: no built-in model URL is configured for HIPPUNFOLD_MODALITY=$HIPPUNFOLD_MODALITY" >&2
  echo "Set HIPPUNFOLD_REQUIRED_MODEL and download/extract it under ${HIPPUNFOLD_CACHE_DIR}/model." >&2
  exit 2
fi

model_tar="${HIPPUNFOLD_CACHE_DIR}/model/${required_model}"
model_dir="${model_tar%.tar}"
legacy_model_tar="${HIPPUNFOLD_CACHE_DIR}/${required_model}"
if [[ ! -f "$model_tar" && -f "$legacy_model_tar" ]]; then
  mv "$legacy_model_tar" "$model_tar"
fi

if [[ ! -f "$model_tar" ]]; then
  download_file "$model_url" "$model_tar"
fi

if [[ ! -s "$model_tar" ]]; then
  echo "ERROR: downloaded model is missing or empty: $model_tar" >&2
  exit 2
fi

if [[ ! -d "$model_dir" ]]; then
  mkdir -p "$model_dir"
  tar -xf "$model_tar" -C "$model_dir"
fi
touch "${model_dir}/.snakemake_timestamp"

atlas_url="$(hippunfold_atlas_url "$HIPPUNFOLD_BUILTIN_ATLAS")"
if [[ -z "$atlas_url" ]]; then
  echo "ERROR: no built-in atlas URL is configured for HIPPUNFOLD_BUILTIN_ATLAS=$HIPPUNFOLD_BUILTIN_ATLAS" >&2
  exit 2
fi
atlas_dir="${HIPPUNFOLD_CACHE_DIR}/atlases_dl/tpl-${HIPPUNFOLD_BUILTIN_ATLAS}"
download_zip_dir "$atlas_url" "$atlas_dir"
atlas_cache_dir="${HIPPUNFOLD_CACHE_DIR}/atlas/${HIPPUNFOLD_BUILTIN_ATLAS}"
atlases_cache_dir="${HIPPUNFOLD_CACHE_DIR}/atlases/tpl-${HIPPUNFOLD_BUILTIN_ATLAS}"
copy_resource_dir "$atlas_dir" "$atlas_cache_dir"
copy_resource_dir "$atlas_dir" "$atlases_cache_dir"

for template_name in "$HIPPUNFOLD_TEMPLATE" "$HIPPUNFOLD_INJECT_TEMPLATE"; do
  template_url="$(hippunfold_template_url "$template_name")"
  if [[ -z "$template_url" ]]; then
    echo "ERROR: no template URL is configured for template=$template_name" >&2
    exit 2
  fi
  download_zip_dir "$template_url" "${HIPPUNFOLD_CACHE_DIR}/template/${template_name}"
done

echo "HippUnfold model cache is ready: $HIPPUNFOLD_CACHE_DIR"
echo "Model tar: $model_tar"
echo "Model directory: $model_dir"
echo "Atlas directory: $atlas_dir"
echo "Atlas cache directory: $atlas_cache_dir"
echo "Alternate atlas cache directory: $atlases_cache_dir"
echo "Template directory: ${HIPPUNFOLD_CACHE_DIR}/template/${HIPPUNFOLD_TEMPLATE}"
echo "Injection template directory: ${HIPPUNFOLD_CACHE_DIR}/template/${HIPPUNFOLD_INJECT_TEMPLATE}"
