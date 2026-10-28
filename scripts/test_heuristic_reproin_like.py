"""Regression checks for the study's ReproIn-like HeuDiConv heuristic."""

import importlib.util
from pathlib import Path
from types import SimpleNamespace


SCRIPT = Path(__file__).with_name('heuristic_reproin_like.py')
SPEC = importlib.util.spec_from_file_location('heuristic', SCRIPT)
HEURISTIC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HEURISTIC)


def templates(protocols):
    seqinfo = [
        SimpleNamespace(protocol_name=protocol, series_id=index)
        for index, protocol in enumerate(protocols, start=1)
    ]
    return [key[0] for key in HEURISTIC.infotodict(seqinfo)]


def test_session_mapping():
    output = templates([
        'anat-T1w_acq-MEMPRvNav',
        'anat-setter_acq-MEMPRSetter',
        'anat-scout_acq-aa_MPR_tra',
        'fmap-epi_acq-opphase_dir-AP',
        'func-bold_task-rest_run-01',
        'func-bold_task-rest_run-01_PhysioLog',
    ])
    assert any('anat/{bids_subject_session_prefix}_acq-MEMPRvNav_rec-RMS_T1w' in path for path in output)
    assert any('fmap/{bids_subject_session_prefix}_acq-opphase_dir-AP_epi' in path for path in output)
    assert any('func/{bids_subject_session_prefix}_task-rest_run-01_bold' in path for path in output)
    assert not any('anat/{bids_subject_session_prefix}_acq-MEMPRvNav_T1w' in path for path in output)
    assert not any(token in path.lower() for path in output for token in ('setter', 'scout', 'physiolog'))


def test_duplicate_t1w_gets_run_entities():
    output = templates([
        'anat-T1w_acq-MEMPRvNav',
        'anat-T1w_acq-MEMPRvNav',
    ])
    assert len(output) == 2
    assert any('run-01_T1w' in path for path in output)
    assert any('run-02_T1w' in path for path in output)


def test_staging_follows_symlinked_dicoms():
    job_script = Path(__file__).with_name('heudiconv_job.sbatch').read_text()
    assert 'find -L "${SERIES_PATH}"' in job_script
    assert "-iname '*.dicom'" in job_script
    assert "-iname '*.dcm'" in job_script
    staging_find = job_script.split('find -L "${SERIES_PATH}"', 1)[1].split('-print0', 1)[0]
    assert '-maxdepth 1' not in staging_find


if __name__ == '__main__':
    test_session_mapping()
    test_duplicate_t1w_gets_run_entities()
    test_staging_follows_symlinked_dicoms()
    print('heuristic regression checks: OK')
