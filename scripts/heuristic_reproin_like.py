import re


def create_key(template, outtype=('nii.gz',), annotation_classes=None):
    if template is None or not template:
        raise ValueError('Template must be a valid format string')
    return (template, outtype, annotation_classes)


def infotodict(seqinfo):
    """Map this study's ReproIn-like protocol names to BIDS templates."""
    bids_order = ['task', 'acq', 'ce', 'rec', 'dir', 'run', 'echo', 'part']
    candidates = []

    for s in seqinfo:
        pname = s.protocol_name
        if not pname or '-' not in pname:
            continue

        parts = pname.split('_')
        head = parts[0].split('-', 1)
        if len(head) != 2:
            continue

        datatype, suffix = head
        trailing_tokens = {part.lower() for part in parts[1:] if '-' not in part}

        # Localizers, calibration scans, and physiology logs are not fMRIPrep
        # input images. Keeping them would create invalid BIDS suffixes or
        # collide with a valid acquisition.
        if (
            suffix.lower() in {'scout', 'setter'}
            or 'physiolog' in trailing_tokens
        ):
            continue

        entities = {}
        for part in parts[1:]:
            if '-' in part:
                key, value = part.split('-', 1)
                if key in bids_order and value:
                    entities[key] = value

        # heudiconv_job.sbatch stages only the RMS MEMPRvNav source directory.
        # Preserve that source reconstruction in the BIDS name even when its
        # DICOM protocol name does not itself contain an RMS token.
        is_memprvnav_t1w = datatype == 'anat' and suffix == 'T1w' and entities.get('acq') == 'MEMPRvNav'
        if is_memprvnav_t1w:
            entities['rec'] = 'RMS'

        # Support legacy labels such as ``anat-T1w1`` by writing a valid BIDS
        # suffix and moving the number to the run entity.
        numbered_anat = re.fullmatch(r'(T1w|T2w|FLAIR)([0-9]+)', suffix)
        if datatype == 'anat' and numbered_anat:
            suffix, inferred_run = numbered_anat.groups()
            entities.setdefault('run', inferred_run)

        candidates.append({
            'datatype': datatype,
            'suffix': suffix,
            'entities': entities,
            'series_id': s.series_id,
        })

    # Multiple valid series with the same template must get explicit run
    # labels. Otherwise HeuDiConv appends digits after ``T1w`` (``T1w1``),
    # which is not BIDS-valid.
    collision_groups = {}
    for candidate in candidates:
        identity = (
            candidate['datatype'],
            candidate['suffix'],
            tuple((name, candidate['entities'].get(name)) for name in bids_order),
        )
        collision_groups.setdefault(identity, []).append(candidate)

    for group in collision_groups.values():
        if len(group) > 1:
            for run_index, candidate in enumerate(
                sorted(group, key=lambda item: str(item['series_id'])), start=1
            ):
                candidate['entities']['run'] = f'{run_index:02d}'

    info = {}
    for candidate in candidates:
        filename_parts = ['{bids_subject_session_prefix}']
        for entity_key in bids_order:
            value = candidate['entities'].get(entity_key)
            if value:
                filename_parts.append(f'{entity_key}-{value}')
        filename_parts.append(candidate['suffix'])

        out_template = (
            f'{{bids_subject_session_dir}}/'
            f"{candidate['datatype']}/{'_'.join(filename_parts)}"
        )
        key = create_key(out_template)
        info[key] = [candidate['series_id']]

    return info
