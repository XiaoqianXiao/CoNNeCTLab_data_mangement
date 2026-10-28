# CoNNeCTLab MRI Processing Runbook

This repository is an example for a Hyak-based MRI processing release from BIDS input through validated derivatives and frozen provenance. The canonical fMRIPrep production path runs one job per subject and includes every available session for that subject.

This document describes the workflow implemented by `scripts/`.

## Workflow at a Glance

```text
DICOM intake (optional) -> BIDS dataset -> BIDS/SDC preflight -> fMRIPrep pilot
-> approved one-step fMRIPrep array -> output verification + provenance
                                      -> optional Kopah publication
                                      -> optional derivative branches
                                         - HippUnfold
                                         - FIRST
                                         - HCP structural -> HCP functional/FIX
```

Do not run a production array until the pilot and its quality gates have been reviewed. Do not mix derivatives from different releases in the same `FMRIPREP_OUT` or `FS_SUBJECTS_DIR`.

## Processing Paths and Dependencies

| Path | Input | Entry point | Prerequisite |
|---|---|---|---|
| Canonical fMRIPrep | BIDS | `scripts/submit_fmriprep_onestep_array_hyak.sh` | Validated BIDS, SDC audit, cached TemplateFlow, approved pilot |
| HippUnfold | BIDS | `scripts/submit_hippunfold_array_hyak.sh` | Cached models/resources |
| FIRST | fMRIPrep shared anatomy, local or staged from Kopah | `scripts/submit_first_array_hyak.sh` | One native-space shared preprocessed T1w per subject |
| HCP structural | BIDS | `scripts/submit_hcp_structural_array_hyak.sh` | HCP container and structural settings |
| HCP functional/FIX | BIDS + HCP structural output | `scripts/submit_hcp_functional_array_hyak.sh` | `MNINonLinear` output from HCP structural processing |

The HCP path is separate from fMRIPrep.

## 1. Configure a Release

Create a release-specific configuration file from the tracked template:

```bash
cp config/CoNNeCTLab_data_management.env.example config/CoNNeCTLab_data_management.env
```

Before running any command, set `USER_NAME` and `PROJECT_NAME` in `config/CoNNeCTLab_data_management.env` to your own Hyak username and project identifier. These values determine the derived project, storage, log, work, and derivative paths.

Set the project paths, scheduler settings, container images, FreeSurfer license, and output locations. Keep credentials in the external `KOPAH_S3CFG` file; do not add credentials to the environment file or repository.

The fMRIPrep release requires these settings at minimum:

```text
BIDS_DIR                  # BIDS input visible to the job
FMRIPREP_OUT              # fMRIPrep derivative output
FS_SUBJECTS_DIR           # FreeSurfer subject directory
WORK_DIR, LOG_DIR, PROVENANCE_DIR
FS_LICENSE
CONTAINER_RUNTIME, FMRIPREP_IMAGE
TEMPLATEFLOW_HOME
HYAK_ACCOUNT, HYAK_PARTITION
FMRIPREP_ONESTEP_CPUS, FMRIPREP_ONESTEP_MEM_MB
```

For production, preserve the canonical settings in the template:

```text
SUBJECT_ANATOMICAL_REFERENCE=unbiased
RANDOM_SEED=20260904
SLICE_TIME_REF=0.5
```

`FMRIPREP_STAGE_FROM_KOPAH=1` stages a subject and `dataset_description.json` to node-local storage for each fMRIPrep array task. With staging disabled, `BIDS_DIR` must already be accessible on the compute node.

## 2. Prepare BIDS Input

Start here when you have raw DICOM data. Skip this section when a suitable BIDS dataset already exists.

The Flywheel downloader uses the release configuration to select sessions. Review the planned download before transferring any data:

```bash
export FW_KEY='uw-chn.flywheel.io:YOUR_API_KEY'

# Generate the session manifest only; review it before downloading.
scripts/download_data_from_flywheel_to_hyak.sh \
  --config config/CoNNeCTLab_data_management.env --list-only 1

# Download the selected DICOM sessions to Hyak.
scripts/download_data_from_flywheel_to_hyak.sh \
  --config config/CoNNeCTLab_data_management.env --list-only 0

# Unpack the downloaded DICOM archives before conversion.
scripts/un_zip.sh
```

`scripts/submit_dicom_to_nii.sh` submits the local HeuDiConv conversion array. Its DICOM, log, and BIDS destination paths are currently defined inside the script, so review and adapt those paths before using it for a different release.

The BIDS dataset is ready for preflight only when the expected `sub-*` directories, sessions, and fieldmap associations are present.

## 3. Run Preflight Checks

Use the configuration file to inventory the dataset, validate BIDS, and audit fieldmap metadata:

```bash
source config/CoNNeCTLab_data_management.env
scripts/run_dataset_info_report_hyak.sh config/CoNNeCTLab_data_management.env
scripts/run_bids_validator.sh config/CoNNeCTLab_data_management.env
scripts/run_python_hyak.sh config/CoNNeCTLab_data_management.env \
  scripts/audit_sdc_metadata.py "$BIDS_DIR" \
  --output "$LOG_DIR/sdc_metadata_audit.csv"
```

Run these commands in an environment where `BIDS_DIR` and `LOG_DIR` are set from the release configuration. Resolve BIDS validation errors and AP/PA susceptibility-distortion-correction (SDC) mapping issues before starting a pilot.

### Cache offline resources

Hyak production jobs require a populated TemplateFlow cache. Prefetch it from an internet-enabled context before the pilot or array submission:

```bash
scripts/prefetch_templateflow_hyak.sh config/CoNNeCTLab_data_management.env
```

If HippUnfold is planned, cache its models and resources separately:

```bash
scripts/prefetch_hippunfold_models_hyak.sh config/CoNNeCTLab_data_management.env
```

## 4. Run and Review the fMRIPrep Pilot

Set `PARTICIPANT_LABELS` in the configuration to a representative approved subset. Submit the pilot through its Slurm wrapper:

```bash
sbatch scripts/submit_preproduction_pilot_hyak.sbatch config/CoNNeCTLab_data_management.env
```

The pilot runs BIDS validation, the SDC audit, canonical fMRIPrep, output checks, and release-manifest generation. Review its reports, fMRIPrep HTML reports, resource usage, and logs. Freeze accepted settings and container versions before production.

## 5. Run One-Step fMRIPrep Production

Submit one array task per BIDS subject:

```bash
scripts/submit_fmriprep_onestep_array_hyak.sh config/CoNNeCTLab_data_management.env
```

To process selected subjects only:

```bash
scripts/submit_fmriprep_onestep_array_hyak.sh \
  config/CoNNeCTLab_data_management.env sub-305 sub-306
```

The submitter creates a subject list in `LOG_DIR`, verifies the TemplateFlow cache, and passes each subject to `submit_fmriprep_hyak.sbatch`. Each task invokes `run_fmriprep.sh` once with all sessions for that subject visible.

The canonical worker produces native functional-grid, T1w-space, MNI152NLin2009cAsym native-resolution, fsnative, and CIFTI 91k outputs. It then materializes the shared anatomical derivative needed by downstream processing. The shared anatomy requirement is exactly one native-space `*desc-preproc_T1w.nii.gz` in `FMRIPREP_OUT/sub-<label>/anat/`; ambiguous session-specific anatomy causes the task to fail rather than choosing arbitrarily.

Use `FMRIPREP_ONESTEP_ARRAY_CONCURRENCY` to limit concurrent subjects. A value of `0` leaves the Slurm array uncapped.

## 6. Verify and Close the fMRIPrep Release

After all intended jobs complete, check expected outputs and freeze the release record:

```bash
source config/CoNNeCTLab_data_management.env
scripts/run_python_hyak.sh config/CoNNeCTLab_data_management.env \
  scripts/check_fmriprep_outputs.py \
  --fmriprep-dir "$FMRIPREP_OUT" \
  --freesurfer-dir "$FS_SUBJECTS_DIR" \
  --output "$LOG_DIR/fmriprep_output_check.csv"

scripts/run_python_hyak.sh config/CoNNeCTLab_data_management.env \
  scripts/freeze_release_manifest.py \
  --config config/CoNNeCTLab_data_management.env \
  --output "$PROVENANCE_DIR/release_manifest.json"
```

Archive the manifest with the frozen configuration, validator/audit reports, command records, Slurm logs, and output-check report.

### Optional Kopah publication

Set `FMRIPREP_PUBLISH_TO_KOPAH=1` to publish each completed array subject automatically. The script verifies the synchronized upload before local removal; set `FMRIPREP_REMOVE_LOCAL_OUTPUT=1` only when that removal is intended.

To publish an already completed subject explicitly:

```bash
scripts/publish_fmriprep_subject.sh config/CoNNeCTLab_data_management.env sub-305
```

Use `scripts/publish_bids_to_kopah.sh config/CoNNeCTLab_data_management.env` only when publishing the BIDS dataset itself. `scripts/sync_kopah.sh` is the lower-level pull/push utility.

## 7. Run Optional Processing Branches

Run a branch only after its input and branch-specific checks are complete.

### HippUnfold

HippUnfold reads BIDS input and requires the cached model and resources described above:

```bash
scripts/submit_hippunfold_array_hyak.sh config/CoNNeCTLab_data_management.env
```

### FIRST

FIRST reads the fMRIPrep shared anatomical derivative locally, or stages it from Kopah when `FIRST_STAGE_FROM_KOPAH=1`:

```bash
scripts/submit_first_array_hyak.sh config/CoNNeCTLab_data_management.env
```

### HCP pipelines

HCP functional processing depends on completed HCP structural output; it does not consume the fMRIPrep output tree:

```bash
scripts/submit_hcp_structural_array_hyak.sh config/CoNNeCTLab_data_management.env
scripts/submit_hcp_functional_array_hyak.sh config/CoNNeCTLab_data_management.env
```

## Operational Safeguards

- The source BIDS tree remains the record of which sessions are available. `RELEASE_SESSION_LABELS` filters Flywheel acquisition selection; it does not limit fMRIPrep once images are present in `BIDS_DIR`.
- fMRIPrep uses explicit container mounts. `APPTAINER_NO_MOUNT=bind-paths` avoids unavailable site-default mounts on Hyak.
- Do not share `FMRIPREP_OUT`, `FS_SUBJECTS_DIR`, work directories, or provenance locations across incompatible releases.
- Review failed task logs before resubmission. Preserve successful subject outputs unless a deliberate release reset is approved.

## Outputs Outside This Runbook

The scripts do not implement denoising, atlas extraction, connectivity estimation, task GLM, or MVPA. Treat those as downstream analyses with their own documented inputs, quality control, and provenance.
