# MRI Preprocessing Scripts

This directory provides the executable components of the R01/IFOCUS MRI
preprocessing release. fMRIPrep has one supported production path: the
one-step subject-level array.

```bash
scripts/submit_fmriprep_onestep_array_hyak.sh config/mri_preproc.env
```

Each array task invokes `submit_fmriprep_hyak.sbatch` and `run_fmriprep.sh` to
process all anatomy and functional data for one BIDS subject together. The
canonical worker materializes shared anatomy and can publish completed
subject-level derivatives to Kopah.

For required setup, quality gates, output verification, provenance, and
optional derivative branches, follow the repository
[one-step fMRIPrep runbook](../README.md).
