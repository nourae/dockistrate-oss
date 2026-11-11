#!/usr/bin/env python3
"""Import completed live captures and build accessible, shared screenshot galleries."""
import argparse
from collections import defaultdict
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import unquote, urlsplit
from capture.evidence_archive import read_archive, validate_member_name, write_archive
from capture.matrix import GROUPS

ROOT = Path(__file__).resolve().parents[2]
ASSETS = Path('docs/assets/interactive')
PEM = re.compile(rb'-----BEGIN (?:[A-Z ]*PRIVATE KEY|CERTIFICATE)-----')


def safe_path(root, relative, *, mutation=False):
    """Require canonical relative paths with no link or special-file redirection."""
    relative = validate_member_name(str(relative) if isinstance(relative, Path) else relative)
    base = root.resolve()
    target = base
    parts = Path(relative).parts
    for index, part in enumerate(parts):
        target = target / part
        if target.is_symlink():
            raise ValueError('Capture path must not contain symlinks: ' + str(target))
        if target.exists():
            if index < len(parts) - 1 and not target.is_dir():
                raise ValueError('Capture path ancestor must be a directory: ' + str(target))
            if not (target.is_dir() or target.is_file()):
                raise ValueError('Capture path contains a special file: ' + str(target))
            if mutation and target.is_file() and target.stat().st_nlink != 1:
                raise ValueError('Capture destination must not be hardlinked: ' + str(target))
    if not target.resolve().is_relative_to(base):
        raise ValueError('Capture path escapes its root: ' + relative)
    return target


def safe_file(root, relative):
    target = safe_path(root, relative)
    if not target.is_file():
        raise ValueError('Missing or unsafe capture file: ' + str(relative))
    return target


def destination(relative, *, directory=False):
    target = safe_path(ROOT, relative, mutation=True)
    if target.exists() and (not target.is_dir() if directory else not target.is_file()):
        raise ValueError('Unexpected capture destination type: ' + str(target))
    return target


def validate_source_paths(source):
    """Bind every imported/retained asset to one supported capture scenario."""
    module, group, scenario = (source.get(key) for key in ('scenario_module', 'group', 'scenario'))
    if (not all(isinstance(value, str) for value in (module, group, scenario)) or
            module not in GROUPS or group not in GROUPS[module] or scenario != module + '-' + group):
        raise ValueError('Invalid capture scenario/module/group: ' + repr(scenario))
    revision = source.get('source_commit')
    if not isinstance(revision, str) or not re.fullmatch(r'[a-f0-9]{40}', revision):
        raise ValueError('Capture source_commit must be a full commit ID')
    for frame in source['frames']:
        journey = frame.get('journey')
        if (not isinstance(journey, str) or not re.fullmatch(r'[a-z0-9][a-z0-9-]*', journey) or
                not journey.startswith(scenario + '-')):
            raise ValueError('Capture journey is outside its scenario: ' + repr(journey))
        image = Path(validate_member_name(frame['image']))
        transcript = Path(validate_member_name(frame['transcript']))
        if (image.parent != ASSETS / journey or image.suffix != '.png' or
                transcript != image.with_suffix('.txt')):
            raise ValueError('Capture assets must belong to their scenario journey: ' + str(image))
        recording = Path(validate_member_name(frame['pty_log']))
        if recording not in (Path('evidence') / scenario / (journey + '.pty.log'),
                             ASSETS / 'evidence' / scenario / (journey + '.pty.log')):
            raise ValueError('Capture recording is outside its scenario: ' + str(recording))
    archive = source.get('evidence_archive')
    if archive:
        if archive['path'] != str(ASSETS / (scenario + '-recordings.tar.gz')):
            raise ValueError('Capture archive is outside its scenario')
        for name in archive['members']:
            if not Path(validate_member_name(name)).is_relative_to(ASSETS / 'evidence' / scenario):
                raise ValueError('Capture archive member is outside its scenario: ' + name)
    return scenario


def relocated(value):
    if isinstance(value, dict):
        return {key: relocated(item) for key, item in value.items()}
    if isinstance(value, list):
        return [relocated(item) for item in value]
    if isinstance(value, str) and value.startswith('evidence/'):
        return str(ASSETS / value)
    return value


def relevant(frame, section):
    # A command can be reused for fixture setup or recovery in another guide.
    # Keep its named canonical journey plus explicit related journeys here.
    command = frame.get('command')
    family = frame.get('journey_family', frame['journey'])
    return (command in section['commands'] and family.endswith('-' + command)) or any(
        family.endswith('-' + journey) for journey in section.get('journeys', []))


def distinctive(frame):
    title = frame['title']
    return (not frame.get('outside_output') and not frame.get('repeated_setup') and frame['kind'] != 'failure' and title not in
            {'Choose a task', 'Choose a command', 'Return to Home'} and
            not title.startswith('Find '))


def caption(frame, empty_input_caption=None):
    if frame['kind'] == 'input':
        value = frame.get('value', '')
        if value == '[redacted]':
            return 'Enter the demonstration password; the terminal hides its value.'
        if not value:
            return empty_input_caption or 'Press Enter to accept the displayed default or leave the optional value blank.'
        return 'Enter `' + value.replace('`', '\\`') + '`.'
    if frame['kind'] == 'menu':
        selected = frame.get('selected', frame['title'])
        if selected == 'Run':
            return 'Review the collected inputs, then choose **Run**.'
        return 'Choose **' + selected.replace('*', '\\*') + '**.'
    title = re.sub(r' — earlier output \d+$', '', frame['title']).rstrip('.')
    if frame.get('output_page'):
        title += ' (' + frame['output_page'] + ')'
    return title + '.'


def gallery(frames, guide, navigation=False, titles=None, empty_input_caption=None):
    grouped = defaultdict(list)
    for frame in frames:
        if not frame.get('outside_output') and (navigation or distinctive(frame)):
            grouped[frame['journey']].append(frame)
    blocks = []
    for journey, items in grouped.items():
        ordered, pending = [], []
        for frame in items:
            if frame.get('viewport'):
                pending.append(frame)
            else:
                if pending:
                    ordered.extend(sorted(pending, key=lambda f: -f.get('scrollback_steps', 0)))
                    pending = []
                ordered.append(frame)
        ordered.extend(sorted(pending, key=lambda f: -f.get('scrollback_steps', 0)))
        items = ordered
        command = next((frame.get('command') for frame in items if frame.get('command')), None)
        family = items[0].get('journey_family', journey)
        title = next(((titles or {})[suffix] for suffix in sorted(titles or {}, key=len, reverse=True)
                      if family.endswith('-' + suffix)), 'inputs and result')
        label = (command + ' — ' + title) if command else items[-1]['title']
        lines = ['<details>', '<summary>' + html.escape(label) + '</summary>', '']
        for number, frame in enumerate(items, 1):
            image = os.path.relpath(ROOT / frame['image'], guide.parent)
            transcript = os.path.relpath(ROOT / frame['transcript'], guide.parent)
            description = caption(frame, empty_input_caption=empty_input_caption)
            alt = re.sub(r'[*`\[\]]', '', description).rstrip('.')
            indent = ' ' * (len(str(number)) + 2)
            lines += [f'{number}. {description}', '',
                      f'{indent}![{alt}]({image})', '',
                      f'{indent}[Read the captured terminal text]({transcript})', '']
        lines += ['</details>', '']
        blocks.append('\n'.join(lines))
    return '\n'.join(blocks)


def replace_section(source, guide, marker, body):
    start, end = f'<!-- walkthrough: {marker} -->', f'<!-- /walkthrough: {marker} -->'
    pattern = (r'^[ \t]*(?:' + re.escape(f'<!-- screenshots: {marker} -->') +
               '|' + re.escape(start) + r'.*?' + re.escape(end) + r')[ \t]*$')
    replacement = start + '\n\n' + body.rstrip() + '\n\n' + end
    source, count = re.subn(pattern, lambda match: replacement, source, flags=re.M | re.S)
    if count != 1:
        raise ValueError(f'{guide}: expected one insertion marker for {marker}, got {count}')
    return source


def render_documents(frames, sections, coverage):
    """Validate every replacement before any imported file is changed."""
    documents = {}

    def replace(guide, marker, body):
        if guide not in documents:
            documents[guide] = guide.read_text()
        documents[guide] = replace_section(documents[guide], guide, marker, body)

    for marker, section in sections.items():
        selected = [frame for frame in frames if relevant(frame, section)]
        if not selected:
            continue
        guide_path = section.get('guide')
        if guide_path is None:
            owners = {row['guide'].partition('#')[0] for row in coverage['commands']
                      if row['command'] in section['commands']}
            if len(owners) != 1:
                raise ValueError('Ambiguous guide ownership for ' + marker)
            guide_path = owners.pop()
        relative = Path(validate_member_name(guide_path))
        if not relative.is_relative_to('docs') or relative.suffix != '.md':
            raise ValueError('Invalid capture guide destination: ' + guide_path)
        guide = destination(relative)
        replace(guide, marker, gallery(selected, guide, navigation=marker == 'navigation',
                                      titles=section.get('journey_titles'),
                                      empty_input_caption=section.get('empty_input_caption')))
    readme = destination('README.md')
    for marker, journey, field, value, description in (
        ('readme-home', 'http-backend', 'title', 'Choose a task', 'Choose a task from Home.'),
        ('readme-review', 'http-backend', 'title', 'Review the HTTP backend',
         'Review the domain, image and ports before choosing Run.'),
        ('readme-result', 'verify-http', 'kind', 'verification',
         'A request through the proxy returns HTTP 200 and the example application.')):
        matched = [frame for frame in frames if frame.get('journey_family', frame['journey']).endswith('-' + journey)
                   and frame.get(field) == value]
        if matched:
            frame = matched[0]
            replace(readme, marker, f'![{description}]({frame["image"]})\n\n'
                    f'{description} [Read the captured text]({frame["transcript"]}).')
    return documents


def validate_retained_references(documents, coverage, obsolete_assets):
    """Do not prune screenshots/text still used by a Home row or a document."""
    obsolete = {(ROOT / name).resolve() for name in obsolete_assets}
    if not obsolete:
        return
    for row in coverage['commands'] + coverage['home']:
        for image in row.get('screenshots', []):
            if (ROOT / image).resolve() in obsolete:
                name = row.get('command', row.get('feature'))
                raise ValueError(f'{name}: refresh would remove a referenced capture: {image}')
    paths = {ROOT / 'README.md', *documents, *(ROOT / 'docs').rglob('*.md')}
    links = re.compile(r'\]\((<[^>]+>|[^\s)]+)(?:\s+"[^"]*")?\)')
    for path in sorted(paths):
        source = documents[path] if path in documents else path.read_text()
        for raw in links.findall(source):
            target = urlsplit(raw.strip('<>'))
            if target.scheme or target.netloc:
                continue
            if (path.parent / unquote(target.path)).resolve() in obsolete:
                raise ValueError(f'{path}: refresh would remove a referenced capture: {raw}')


def frames_for_rendering(source, manifest_path, root):
    """Derive gallery metadata without changing a capture's stored provenance."""
    frames = []
    for frame in source['frames']:
        frame = dict(frame, provenance=str(manifest_path),
                     optional_branch=source.get('group') == 'branches',
                     capture_scenario=source['scenario'])
        if frame.get('viewport'):
            content = safe_file(root, frame['transcript']).read_text()
            columns = source['terminal']['columns']
            rows = source['terminal']['rows']
            rendered = sum(max(1, (len(line) + columns - 1) // columns) for line in content.splitlines())
            half = max(1, rows // 2)
            backward_pages = max(0, (rendered - rows + half - 1) // half)
            step = frame.get('scrollback_steps', 0)
            frame['outside_output'] = step > backward_pages
            if backward_pages:
                frame['output_page'] = 'start' if step == backward_pages else 'end' if step == 0 else 'continued'
        frames.append(frame)
    return frames


def preserved_frames(replaced_scenarios):
    """Reuse selected evidence from untouched scenarios, preserving its source pin.

    Shared sections and command rows can contain several independently captured
    scenarios. Verify retained inputs before rendering them alongside a refresh;
    never repack their archives or relabel them with the new capture's metadata.
    """
    frames = []
    for path in sorted((ROOT / ASSETS).glob('*-provenance.json')):
        source = json.loads(safe_file(ROOT, path.relative_to(ROOT)).read_text())
        validate_source_paths(source)
        if source.get('scenario') in replaced_scenarios:
            continue
        if (source.get('status') != 'passed' or
                not re.fullmatch(r'[a-f0-9]{40}', source.get('source_commit', '')) or
                path.name != source.get('scenario', '') + '-provenance.json'):
            raise ValueError('Invalid preserved capture provenance: ' + str(path))
        archive = source.get('evidence_archive')
        if not archive:
            raise ValueError('Preserved capture has no evidence archive: ' + str(path))
        members = read_archive(safe_file(ROOT, archive['path']), expected_archive_sha256=archive['sha256'])
        if set(members) != set(archive['members']):
            raise ValueError('Preserved archive member inventory differs from provenance: ' + str(path))
        for name, data in members.items():
            expected = archive['members'][name]
            if hashlib.sha256(data).hexdigest() != expected['sha256'] or len(data) != expected['size']:
                raise ValueError('Preserved evidence member hash/size mismatch: ' + name)
            if PEM.search(data):
                raise ValueError('Certificate/key material in preserved evidence: ' + name)
        for frame in source['frames']:
            if frame['kind'] == 'failure':
                raise ValueError('Preserved capture contains a failed frame: ' + str(path))
            for field in ('image', 'transcript'):
                asset = safe_file(ROOT, frame[field])
                data = asset.read_bytes()
                if hashlib.sha256(data).hexdigest() != frame[field + '_sha256']:
                    raise ValueError('Preserved capture hash mismatch: ' + str(asset))
                if field == 'image' and not data.startswith(b'\x89PNG\r\n\x1a\n'):
                    raise ValueError('Preserved capture is not a PNG: ' + str(asset))
            recording = members.get(frame['pty_log'])
            if recording is None or not 0 < frame.get('pty_byte_offset', 0) <= len(recording):
                raise ValueError('Preserved capture has no valid terminal recording offset: ' + str(path))
        frames.extend(frames_for_rendering(source, path.relative_to(ROOT), ROOT))
    return frames


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifacts', type=Path, nargs='+')
    parser.add_argument('--allow-partial', action='store_true', help='Authoring only; leave uncovered commands pending')
    args = parser.parse_args()
    sections = {}
    for path in sorted((ROOT / 'scripts/docs/capture').glob('*_sections.json')):
        for marker, section in json.loads(path.read_text()).items():
            if marker in sections:
                raise ValueError('Duplicate screenshot section: ' + marker)
            sections[marker] = section
    coverage_path = destination('docs/interactive-coverage.json')
    coverage = json.loads(coverage_path.read_text())
    frames, manifests, copies, prepared = [], {}, [], []
    previous_assets = set()
    for artifact in args.artifacts:
        artifact = artifact.absolute()
        if artifact.is_symlink() or not artifact.is_dir():
            raise ValueError('Capture artifact must be a real directory: ' + str(artifact))
        for path in sorted(artifact.rglob('*-provenance.json')):
            path = safe_file(artifact, path.relative_to(artifact))
            source = json.loads(path.read_text())
            scenario = validate_source_paths(source)
            relative = path.relative_to(artifact.resolve())
            expected = ASSETS / (scenario + '-provenance.json')
            if len(relative.parts) < len(expected.parts) or relative.parts[-len(expected.parts):] != expected.parts:
                raise ValueError('Capture manifest is outside its expected artifact location: ' + str(path))
            if source['status'] != 'passed':
                raise ValueError(f'{path}: only completed, successful scenarios may be imported')
            root = path.parents[3]
            revision = source['source_commit']
            subprocess.run(['git', 'diff', '--exit-code', revision, 'HEAD', '--',
                            'dockistrate.sh', 'lib', 'config', 'completion'], cwd=ROOT,
                           check=True, stdout=subprocess.DEVNULL)
            for frame in source['frames']:
                if frame['kind'] == 'failure':
                    raise ValueError('Successful manifest contains a failed frame')
                for field in ('image', 'transcript'):
                    original = safe_file(root, frame[field])
                    if hashlib.sha256(original.read_bytes()).hexdigest() != frame[field + '_sha256']:
                        raise ValueError('Capture hash mismatch: ' + str(original))
                    if field == 'image' and not original.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'):
                        raise ValueError('Capture is not a PNG: ' + str(original))
                    copies.append((original, ROOT / frame[field]))
                safe_file(root, frame['pty_log'])
            if scenario in manifests:
                raise ValueError('Duplicate scenario; select one successful run: ' + scenario)
            evidence = safe_path(root, Path('evidence') / scenario)
            if not evidence.is_dir():
                evidence = safe_path(root, ASSETS / 'evidence' / scenario)
            if not evidence.is_dir():
                raise ValueError('Capture has no evidence directory: ' + scenario)
            omitted = []
            for original in evidence.rglob('*'):
                original = safe_path(root, original.relative_to(root))
                if original.is_file():
                    if original.suffix in {'.pem', '.key', '.p12', '.pcap', '.pcapng'}:
                        raise ValueError('Runtime material must not be imported: ' + str(original))
                    target = ROOT / ASSETS / 'evidence' / scenario / original.relative_to(evidence)
                    data = original.read_bytes()
                    if PEM.search(data):
                        if original.name.endswith(('.pty.log', '.events.jsonl')):
                            raise ValueError('Certificate/key material appeared in an original terminal recording: ' + str(original))
                        if original.name == 'commands.jsonl':
                            continue
                        omitted.append(str(original.relative_to(root)))
                    else:
                        copies.append((original, target))
            commands = evidence / 'commands.jsonl'
            if commands.is_file():
                records = []
                copies = [(original, target) for original, target in copies if original != commands]
                for line in commands.read_text().splitlines():
                    record = json.loads(line)
                    stdin = record.get('input')
                    if isinstance(stdin, str) and PEM.search(stdin.encode()):
                        record['input'] = '[certificate material omitted from documentation evidence]'
                        record['input_sha256'] = hashlib.sha256(stdin.encode()).hexdigest()
                    if record.get('log') in omitted:
                        record['omitted_log'] = record.pop('log')
                        record['omission_reason'] = 'Certificate material excluded; fingerprints retained separately.'
                    if PEM.search(json.dumps(record).encode()):
                        raise ValueError('Unexpected certificate material outside structured verification stdin')
                    records.append(json.dumps(relocated(record)))
                prepared.append((ROOT / ASSETS / 'evidence' / scenario / 'commands.jsonl',
                                 '\n'.join(records) + '\n'))
            source = relocated(source)
            source['import'] = {'original_manifest_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                                'evidence_paths_relocated': True,
                                'omitted_nonterminal_certificate_logs': omitted}
            manifest_target = ASSETS / (scenario + '-provenance.json')
            previous = ROOT / manifest_target
            if previous.is_file():
                previous_source = json.loads(safe_file(ROOT, manifest_target).read_text())
                if validate_source_paths(previous_source) != scenario:
                    raise ValueError('Previous capture manifest has a different scenario')
                for frame in previous_source['frames']:
                    previous_assets.update(frame[field] for field in ('image', 'transcript'))
            manifests[scenario] = (manifest_target, source)
            frames.extend(frames_for_rendering(source, manifest_target, root))
    imported_frame_count = len(frames)
    frames.extend(preserved_frames(manifests))
    # Teach the main path before optional inputs captured in separate VMs.
    scenario_order = {name + '-' + group: rank for rank, (name, group) in enumerate(
        (name, group) for name, groups in GROUPS.items() for group in groups)}
    frames.sort(key=lambda frame: (frame.get('optional_branch', False),
                                  scenario_order.get(frame['capture_scenario'], len(scenario_order))))
    owners = {}
    for marker, section in sections.items():
        for command in section['commands']:
            if command in owners:
                raise ValueError('Command has multiple canonical screenshot sections: ' + command)
            owners[command] = marker
    expected_commands = {row['command'] for row in coverage['commands']}
    if set(owners) != expected_commands:
        raise ValueError('Screenshot sections do not match the command inventory')
    by_command = defaultdict(list)
    for frame in frames:
        command = frame.get('command')
        if command in owners and distinctive(frame) and relevant(frame, sections[owners[command]]):
            by_command[command].append(frame)
    missing = [row['command'] for row in coverage['commands']
               if not any(frame['kind'] == 'result' for frame in by_command[row['command']])]
    lost = [row['command'] for row in coverage['commands']
            if row['command'] in missing and row.get('screenshots') and row.get('evidence')]
    if lost:
        raise ValueError('Refresh omits results for previously captured commands: ' + ', '.join(lost))
    if missing and not args.allow_partial:
        raise ValueError('Commands without completed interactive results: ' + ', '.join(missing))
    retained = {frame['image'] for frame in frames if any(
        relevant(frame, section) and not frame.get('outside_output') and
        (marker == 'navigation' or distinctive(frame)) for marker, section in sections.items())}
    # Home and the first review also appear directly in the short README.
    retained.update(frame['image'] for frame in frames if
                    frame.get('journey_family', frame['journey']).endswith('-http-backend') and
                    frame['title'] in {'Choose a task', 'Review the HTTP backend'})
    selected_files = {name for frame in frames if frame['image'] in retained
                      for name in (frame['image'], frame['transcript'])}
    for row in coverage['commands']:
        captured = by_command[row['command']]
        if row['command'] in missing:
            continue
        row['screenshots'] = [frame['image'] for frame in captured]
        row['evidence'] = sorted({frame['provenance'] for frame in captured})
        row['verification'] = 'live-verified'
        if row['command'] == 'renew-certs':
            row['verification'] = 'not-live-verified'
            row['limitation'] = ('The real renewal scan is captured, but the disposable VM has no '
                                 'publicly issued certificate due for renewal. Actual ACME renewal is not live verified.')
        elif row['command'] == 'add-cert':
            row['limitations'] = ['Self-signed and imported certificates are verified. Public ACME issuance '
                                  'requires controlled DNS and public reachability and is not live verified.']
    home = sections['navigation'].get('home_features', {})
    for row in coverage['home']:
        selector = home.get('home-' + row['feature'], {})
        matched = [frame for frame in frames if selector and all(
            frame.get('journey_family', frame['journey']).endswith('-' + value) if key == 'journey' else frame.get(key) == value
            for key, value in selector.items())]
        if matched:
            row.update(screenshots=[frame['image'] for frame in matched], verification='live-verified',
                       evidence=sorted({frame['provenance'] for frame in matched}))
    document_updates = render_documents(frames, sections, coverage)
    obsolete_assets = previous_assets - selected_files
    validate_retained_references(document_updates, coverage, obsolete_assets)
    # Validate every mutation before the first write/delete. Recheck each target
    # at use as well; never follow links supplied by artifacts or an old checkout.
    for name in selected_files | obsolete_assets:
        destination(name)
    for scenario, (manifest_target, _) in manifests.items():
        destination(manifest_target)
        destination(ASSETS / (scenario + '-recordings.tar.gz'))
        legacy = destination(ASSETS / 'evidence' / scenario, directory=True)
        for path in legacy.rglob('*'):
            safe_path(ROOT, path.relative_to(ROOT), mutation=True)
    for path in (*document_updates, coverage_path):
        destination(path.relative_to(ROOT))
    # Evidence is generated, immutable documentation input. Replace only these
    # imported scenarios so obsolete nonterminal certificate logs cannot remain.
    for scenario in manifests:
        legacy = destination(ASSETS / 'evidence' / scenario, directory=True)
        if legacy.exists():
            shutil.rmtree(legacy)
    evidence_members = {scenario: {} for scenario in manifests}
    for original, target in copies:
        relative = target.relative_to(ROOT)
        if relative.is_relative_to(ASSETS / 'evidence'):
            scenario = relative.parts[len(ASSETS.parts) + 1]
            evidence_members[scenario][relative.as_posix()] = original.read_bytes()
        elif relative.as_posix() in selected_files:
            target = destination(relative)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, target)
    for target, content in prepared:
        relative = target.relative_to(ROOT)
        scenario = relative.parts[len(ASSETS.parts) + 1]
        evidence_members[scenario][relative.as_posix()] = content.encode()
    for scenario, (_, source) in manifests.items():
        archive = ASSETS / (scenario + '-recordings.tar.gz')
        source['evidence_archive'] = dict(path=str(archive), **write_archive(destination(archive), evidence_members[scenario]))
        source['frames'] = [frame for frame in source['frames'] if frame['image'] in retained]
        source['import']['selected_screenshot_count'] = len(source['frames'])
    # Remove obsolete selections only from the scenarios being replaced.
    for name in sorted(obsolete_assets):
        destination(name).unlink(missing_ok=True)
    for target, source in manifests.values():
        target = destination(target)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(source, indent=2) + '\n')
    for guide, source in document_updates.items():
        destination(guide.relative_to(ROOT)).write_text(source)
    destination(coverage_path.relative_to(ROOT)).write_text(json.dumps(coverage, indent=2) + '\n')
    print(f'Imported {imported_frame_count} frames from {len(manifests)} successful scenarios; '
          f'preserved {len(frames) - imported_frame_count} selected frames from unaffected scenarios; '
          f'{len(missing)} commands still require capture.')


if __name__ == '__main__':
    main()
