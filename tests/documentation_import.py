"""Exercise partial capture imports against real files and local Git history."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


REPOSITORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY / 'scripts/docs'))
spec = importlib.util.spec_from_file_location('documentation_importer', REPOSITORY / 'scripts/docs/import_captures.py')
importer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(importer)


class PartialCaptureImport(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='dockistrate-import-check-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / 'repository'
        self.root.mkdir()
        self.artifacts = Path(self.directory.name) / 'artifacts'
        self.git('init', '-q')
        (self.root / 'dockistrate.sh').write_text('# Read-only runtime identity fixture.\n')
        self.git('add', 'dockistrate.sh')
        self.git('-c', 'user.name=Documentation test', '-c', 'user.email=docs@example.com',
                 'commit', '-qm', 'Create runtime fixture')
        self.revision = self.git('rev-parse', 'HEAD').strip()
        root_patch = patch.object(importer, 'ROOT', self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)
        sections = self.root / 'scripts/docs/capture/test_sections.json'
        sections.parent.mkdir(parents=True)
        sections.write_text(json.dumps({
            'navigation': {'commands': [], 'journeys': [], 'home_features': {}},
            'security-rules': {
                'guide': 'docs/guides/rules.md',
                'commands': ['add-security-rule', 'update-security-rule'],
                'journeys': ['security-rules', 'security-condition-branches', 'security-replace-conditions'],
            },
        }))
        self.guide = self.root / 'docs/guides/rules.md'
        self.guide.parent.mkdir(parents=True)
        self.guide.write_text('# Request rules\n\n<!-- screenshots: security-rules -->\n')
        (self.root / 'README.md').write_text('# Fixture readme\n')
        self.coverage = self.root / 'docs/interactive-coverage.json'
        self.coverage.write_text(json.dumps({
            'categories': ['Security'], 'home': [], 'commands': [
                {'command': command, 'category': 'Security', 'guide': 'docs/guides/rules.md',
                 'verification': 'pending', 'screenshots': [], 'evidence': []}
                for command in ('add-security-rule', 'update-security-rule')],
        }))
        self.main = self.capture('initial', 'security-rules', 'rules', [
            ('security-rules', 'add-security-rule', 'Original main', False)])
        self.branch = self.capture('initial', 'security-branches', 'branches', [
            ('security-condition-branches', 'add-security-rule', 'Original branch', True),
            ('security-replace-conditions', 'update-security-rule', 'Original replacement', False)])
        self.run_import(self.artifacts / 'initial')
        self.git('add', '.')
        self.git('-c', 'user.name=Documentation test', '-c', 'user.email=docs@example.com',
                 'commit', '-qm', 'Record existing documentation evidence')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True, stderr=subprocess.PIPE)

    def capture(self, bundle, scenario, group, observations):
        root = self.artifacts / bundle
        frames = []
        for suffix, command, title, paged in observations:
            journey = scenario + '-' + suffix
            stem = title.lower().replace(' ', '-')
            image = Path('docs/assets/interactive') / journey / (stem + '.png')
            transcript = image.with_suffix('.txt')
            recording = Path('evidence') / scenario / (journey + '.pty.log')
            text = title + '\n' + ('observed row\n' * 55 if paged else '')
            image_data = b'\x89PNG\r\n\x1a\n' + title.encode()
            raw = b'\x1b[H\x1b[2J' + text.replace('\n', '\r\n').encode()
            for relative, data in ((image, image_data), (transcript, text.encode()), (recording, raw)):
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
            frame = {'journey': journey, 'journey_family': journey, 'step': 1, 'session_index': 1,
                     'command': command, 'title': title, 'kind': 'result', 'image': str(image),
                     'transcript': str(transcript), 'pty_log': str(recording), 'pty_byte_offset': len(raw),
                     'image_sha256': hashlib.sha256(image_data).hexdigest(),
                     'transcript_sha256': hashlib.sha256(text.encode()).hexdigest()}
            if paged:
                frame.update(viewport='bottom', scrollback_steps=0)
            frames.append(frame)
        manifest = root / 'docs/assets/interactive' / (scenario + '-provenance.json')
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text(json.dumps({
            'schema_version': 1, 'status': 'passed', 'source_commit': self.revision,
            'scenario': scenario, 'group': group, 'scenario_module': scenario.split('-', 1)[0],
            'github_run_id': bundle, 'terminal': {'columns': 90, 'rows': 48},
            'checks': [{'label': 'fixture-outcome', 'status': 'passed'}], 'frames': frames,
        }))
        return frames

    def run_import(self, artifact, partial=False):
        argv = ['import_captures.py', str(artifact)] + (['--allow-partial'] if partial else [])
        with patch.object(sys, 'argv', argv), contextlib.redirect_stdout(io.StringIO()):
            importer.main()

    def row(self, command):
        return next(row for row in json.loads(self.coverage.read_text())['commands'] if row['command'] == command)

    def snapshot(self):
        return {path.relative_to(self.root): path.read_bytes() for path in self.root.rglob('*')
                if path.is_file() and '.git' not in path.relative_to(self.root).parts}

    def unsafe_refresh(self):
        self.capture('unsafe', 'security-rules', 'rules', [
            ('security-rules', 'add-security-rule', 'Refreshed main', False)])
        artifact = self.artifacts / 'unsafe'
        manifest = artifact / 'docs/assets/interactive/security-rules-provenance.json'
        return artifact, manifest, json.loads(manifest.read_text())

    def assert_rejected_without_mutation(self, artifact):
        def state(root):
            return {path.relative_to(root): ('link', os.readlink(path)) if path.is_symlink()
                    else ('file', path.read_bytes()) if path.is_file() else ('directory',)
                    for path in root.rglob('*') if '.git' not in path.relative_to(root).parts}
        before = state(self.root)
        outside = Path(self.directory.name) / 'outside'
        outside_before = state(outside) if outside.exists() else {}
        with self.assertRaises(ValueError):
            self.run_import(artifact, partial=True)
        self.assertEqual(state(self.root), before)
        self.assertEqual(state(outside) if outside.exists() else {}, outside_before)

    def test_absolute_scenario_cannot_delete_an_outside_directory(self):
        artifact, manifest, source = self.unsafe_refresh()
        victim = Path(self.directory.name) / 'outside/keep'
        victim.mkdir(parents=True)
        (victim / 'sentinel.txt').write_text('Do not delete this directory.\n')
        source.update(scenario=str(victim), frames=[])
        manifest.write_text(json.dumps(source))
        self.assert_rejected_without_mutation(artifact)

    def test_scenario_must_match_a_supported_module_and_group(self):
        artifact, manifest, source = self.unsafe_refresh()
        for updates in ({'scenario': '../escape'}, {'scenario': 'security-unknown', 'group': 'unknown'},
                        {'scenario_module': 'operations'}, {'group': 'branches'},
                        {'scenario': 'security-rules/child'}):
            with self.subTest(updates=updates):
                manifest.write_text(json.dumps(dict(source, **updates)))
                self.assert_rejected_without_mutation(artifact)

    def test_revision_cannot_inject_git_output_option(self):
        artifact, manifest, source = self.unsafe_refresh()
        victim = Path(self.directory.name) / 'outside/sentinel.txt'
        victim.parent.mkdir()
        victim.write_text('Keep this file intact.\n')
        source['source_commit'] = '--output=' + str(victim)
        manifest.write_text(json.dumps(source))
        self.assert_rejected_without_mutation(artifact)

    def test_frame_paths_cannot_target_repository_files_or_other_scenarios(self):
        artifact, manifest, source = self.unsafe_refresh()
        original = artifact / source['frames'][0]['transcript']
        for name in ('dockistrate.sh', self.branch[0]['transcript'], str(original),
                     'docs/assets/interactive/security-rules-security-rules/../escape.txt'):
            with self.subTest(name=name):
                destination = artifact / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(original.read_bytes())
                changed = json.loads(json.dumps(source))
                changed['frames'][0]['transcript'] = name
                manifest.write_text(json.dumps(changed))
                self.assert_rejected_without_mutation(artifact)

    def test_frame_image_cannot_claim_another_scenarios_journey(self):
        artifact, manifest, source = self.unsafe_refresh()
        frame = source['frames'][0]
        for field in ('image', 'transcript'):
            destination = artifact / self.branch[0][field]
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes((artifact / frame[field]).read_bytes())
            frame[field] = self.branch[0][field]
        frame['journey'] = frame['journey_family'] = self.branch[0]['journey']
        manifest.write_text(json.dumps(source))
        self.assert_rejected_without_mutation(artifact)

    def test_manifest_must_have_its_expected_location_inside_the_supplied_artifact(self):
        artifact, manifest, _ = self.unsafe_refresh()
        shallow = artifact / manifest.name
        manifest.rename(shallow)
        self.assert_rejected_without_mutation(artifact)

    def test_source_evidence_symlinks_are_rejected_before_import(self):
        artifact, _, _ = self.unsafe_refresh()
        outside = Path(self.directory.name) / 'outside'
        outside.mkdir()
        sentinel = outside / 'sentinel.txt'
        sentinel.write_text('Unrelated private source.\n')
        extra = artifact / 'evidence/security-rules/extra.log'
        extra.symlink_to(sentinel)
        self.assert_rejected_without_mutation(artifact)
        extra.unlink()
        evidence = extra.parent
        shutil.move(str(evidence), outside / 'evidence')
        evidence.symlink_to(outside / 'evidence', target_is_directory=True)
        self.assert_rejected_without_mutation(artifact)

    def test_asset_destinations_cannot_follow_symlinks_or_hardlinks(self):
        artifact, _, source = self.unsafe_refresh()
        destination = self.root / source['frames'][0]['image']
        destination.parent.mkdir(parents=True, exist_ok=True)
        outside = Path(self.directory.name) / 'outside'
        outside.mkdir()
        sentinel = outside / 'sentinel.png'
        sentinel.write_bytes(b'Outside image must survive unchanged.')
        for kind in ('symlink', 'hardlink'):
            with self.subTest(kind=kind):
                if kind == 'symlink':
                    destination.symlink_to(sentinel)
                else:
                    os.link(sentinel, destination)
                self.assert_rejected_without_mutation(artifact)
                destination.unlink()

    def test_evidence_cleanup_cannot_follow_an_ancestor_symlink(self):
        artifact, _, _ = self.unsafe_refresh()
        outside = Path(self.directory.name) / 'outside'
        victim = outside / 'security-rules'
        victim.mkdir(parents=True)
        (victim / 'sentinel.txt').write_text('Do not remove this evidence lookalike.\n')
        (self.root / 'docs/assets/interactive/evidence').symlink_to(outside, target_is_directory=True)
        self.assert_rejected_without_mutation(artifact)

    def test_regular_file_ancestor_is_rejected_before_legacy_evidence_cleanup(self):
        frames = self.capture('unsafe', 'security-rules', 'rules', [
            ('other-security-rules', 'add-security-rule', 'Refreshed main', False)])
        parent = (self.root / frames[0]['image']).parent
        parent.write_text('This existing file is not an asset directory.\n')
        legacy = self.root / 'docs/assets/interactive/evidence/security-rules/legacy.log'
        legacy.parent.mkdir(parents=True)
        legacy.write_text('Keep evidence until every destination has passed validation.\n')
        self.assert_rejected_without_mutation(self.artifacts / 'unsafe')

    def test_all_document_and_metadata_writes_are_preflighted_for_links(self):
        artifact, _, _ = self.unsafe_refresh()
        outside = Path(self.directory.name) / 'outside'
        outside.mkdir()
        for relative in ('docs/assets/interactive/security-rules-provenance.json',
                         'docs/assets/interactive/security-rules-recordings.tar.gz',
                         'docs/interactive-coverage.json', 'docs/guides/rules.md'):
            for kind in ('symlink', 'hardlink'):
                with self.subTest(relative=relative, kind=kind):
                    destination = self.root / relative
                    data = destination.read_bytes()
                    sentinel = outside / destination.name
                    sentinel.write_bytes(data)
                    destination.unlink()
                    if kind == 'symlink':
                        destination.symlink_to(sentinel)
                    else:
                        os.link(sentinel, destination)
                    self.assert_rejected_without_mutation(artifact)
                    destination.unlink()
                    destination.write_bytes(data)

    def test_previous_manifest_cannot_prune_another_scenarios_assets(self):
        artifact, _, _ = self.unsafe_refresh()
        previous = self.root / 'docs/assets/interactive/security-rules-provenance.json'
        source = json.loads(previous.read_text())
        source['frames'].append(dict(self.branch[0], image='dockistrate.sh', transcript='README.md'))
        previous.write_text(json.dumps(source))
        self.assert_rejected_without_mutation(artifact)

    def test_partial_refresh_preserves_other_scenario_gallery_assets_and_coverage(self):
        assets = self.root / 'docs/assets/interactive'
        preserved = {path: path.read_bytes() for path in assets.rglob('*')
                     if path.is_file() and 'security-branches' in str(path.relative_to(assets))}
        unchanged_row = self.row('update-security-rule')
        new = self.capture('refresh', 'security-rules', 'rules', [
            ('security-rules', 'add-security-rule', 'Refreshed main', False)])

        self.run_import(self.artifacts / 'refresh', partial=True)

        guide = self.guide.read_text()
        self.assertIn('Refreshed main.', guide)
        self.assertNotIn('Original main.', guide)
        self.assertIn('Original branch (end).', guide)
        self.assertIn('Original replacement.', guide)
        self.assertLess(guide.index('Refreshed main.'), guide.index('Original branch (end).'))
        for path, data in preserved.items():
            self.assertEqual(path.read_bytes(), data, str(path))
        self.assertFalse((self.root / self.main[0]['image']).exists())
        row = self.row('add-security-rule')
        self.assertEqual(set(row['screenshots']), {new[0]['image'], self.branch[0]['image']})
        self.assertEqual(set(row['evidence']), {
            'docs/assets/interactive/security-rules-provenance.json',
            'docs/assets/interactive/security-branches-provenance.json'})
        self.assertEqual(self.row('update-security-rule'), unchanged_row)

    def test_section_empty_input_caption_overrides_only_blank_inputs(self):
        section_path = self.root / 'scripts/docs/capture/test_sections.json'
        sections = json.loads(section_path.read_text())
        coverage = json.loads(self.coverage.read_text())
        empty = dict(self.main[0], kind='input', title='Enter value', value='')
        entered = dict(empty, value='--memory 256m')
        hidden = dict(empty, value='[redacted]')
        custom = 'Press Enter on an empty line to finish entering Docker options.'
        default = 'Press Enter to accept the displayed default or leave the optional value blank.'

        sections['security-rules']['empty_input_caption'] = custom
        rendered = importer.render_documents([empty, entered, hidden], sections, coverage)[self.guide]
        self.assertIn(custom, rendered)
        self.assertNotIn(default, rendered)
        self.assertIn('Enter `--memory 256m`.', rendered)
        self.assertIn('Enter the demonstration password; the terminal hides its value.', rendered)

        del sections['security-rules']['empty_input_caption']
        ordinary = importer.render_documents([empty], sections, coverage)[self.guide]
        self.assertIn(default, ordinary)
        self.assertNotIn(custom, ordinary)

    def test_complete_existing_evidence_allows_one_scenario_refresh_without_partial_flag(self):
        self.capture('refresh', 'security-rules', 'rules', [
            ('security-rules', 'add-security-rule', 'Refreshed main', False)])
        self.run_import(self.artifacts / 'refresh')
        self.assertIn('Original replacement.', self.guide.read_text())
        self.assertEqual(self.row('update-security-rule')['verification'], 'live-verified')

    def test_corrupt_preserved_archive_is_rejected_before_replacing_documentation(self):
        archive = self.root / 'docs/assets/interactive/security-branches-recordings.tar.gz'
        archive.write_bytes(archive.read_bytes() + b'changed')
        before = {path: path.read_bytes() for path in (self.guide, self.coverage,
                  self.root / 'docs/assets/interactive/security-rules-provenance.json')}
        new = self.capture('refresh', 'security-rules', 'rules', [
            ('security-rules', 'add-security-rule', 'Refreshed main', False)])
        with self.assertRaisesRegex(ValueError, 'hash|SHA-256|sha256'):
            self.run_import(self.artifacts / 'refresh', partial=True)
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data, str(path))
        self.assertFalse((self.root / new[0]['image']).exists())

    def test_partial_refresh_cannot_remove_a_previously_captured_command_result(self):
        self.capture('incomplete', 'security-branches', 'branches', [
            ('security-condition-branches', 'add-security-rule', 'New branch', False)])
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, 'previously captured.*update-security-rule'):
            self.run_import(self.artifacts / 'incomplete', partial=True)
        self.assertEqual(self.snapshot(), before)

    def test_reusing_old_asset_names_for_inputs_does_not_replace_a_command_result(self):
        frames = self.capture('inputs-only', 'security-branches', 'branches', [
            ('security-condition-branches', 'add-security-rule', 'Original branch', True),
            ('security-replace-conditions', 'update-security-rule', 'Original replacement', False)])
        path = self.artifacts / 'inputs-only/docs/assets/interactive/security-branches-provenance.json'
        source = json.loads(path.read_text())
        source['frames'][1].update(kind='input', value='new condition')
        path.write_text(json.dumps(source))
        self.assertEqual(frames[1]['image'], self.branch[1]['image'])
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, 'previously captured.*update-security-rule'):
            self.run_import(self.artifacts / 'inputs-only', partial=True)
        self.assertEqual(self.snapshot(), before)

    def test_initial_authoring_import_can_leave_never_captured_commands_pending(self):
        shutil.rmtree(self.root / 'docs/assets/interactive')
        coverage = json.loads(self.coverage.read_text())
        for row in coverage['commands']:
            row.update(verification='pending', screenshots=[], evidence=[])
        self.coverage.write_text(json.dumps(coverage))
        self.guide.write_text('# Request rules\n\n<!-- screenshots: security-rules -->\n')
        self.capture('partial', 'security-rules', 'rules', [
            ('security-rules', 'add-security-rule', 'First capture', False)])
        self.run_import(self.artifacts / 'partial', partial=True)
        self.assertEqual(self.row('add-security-rule')['verification'], 'live-verified')
        self.assertEqual(self.row('update-security-rule')['verification'], 'pending')
        self.assertEqual(self.row('update-security-rule')['screenshots'], [])

    def test_missing_guide_marker_fails_before_any_asset_or_provenance_mutation(self):
        self.guide.write_text(self.guide.read_text().replace(
            '<!-- walkthrough: security-rules -->', '<!-- missing: security-rules -->'))
        self.capture('refresh', 'security-rules', 'rules', [
            ('security-rules', 'add-security-rule', 'Refreshed main', False)])
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, 'expected one insertion marker for security-rules'):
            self.run_import(self.artifacts / 'refresh', partial=True)
        self.assertEqual(self.snapshot(), before)

    def test_missing_readme_marker_fails_before_any_asset_or_provenance_mutation(self):
        self.capture('readme', 'core-all', 'all', [
            ('http-backend', 'add-backend', 'Choose a task', False)])
        path = self.artifacts / 'readme/docs/assets/interactive/core-all-provenance.json'
        source = json.loads(path.read_text())
        source['scenario_module'] = 'core'
        source['frames'][0].update(kind='menu', selected='Add a new backend')
        path.write_text(json.dumps(source))
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, 'expected one insertion marker for readme-home'):
            self.run_import(self.artifacts / 'readme', partial=True)
        self.assertEqual(self.snapshot(), before)

    def test_omitted_readme_verification_is_rejected_even_when_commands_remain_covered(self):
        sections_path = self.root / 'scripts/docs/capture/test_sections.json'
        sections = json.loads(sections_path.read_text())
        sections['security-rules']['journeys'].append('verify-http')
        sections_path.write_text(json.dumps(sections))
        (self.root / 'README.md').write_text('# Fixture readme\n\n<!-- screenshots: readme-result -->\n')
        self.capture('readme', 'core-all', 'all', [
            ('verify-http', None, 'Original HTTP verification', False)])
        manifest = self.artifacts / 'readme/docs/assets/interactive/core-all-provenance.json'
        source = json.loads(manifest.read_text())
        source['scenario_module'] = 'core'
        source['frames'][0]['kind'] = 'verification'
        manifest.write_text(json.dumps(source))
        self.run_import(self.artifacts / 'readme')
        self.capture('refresh-core', 'core-all', 'all', [
            ('security-rules', 'add-security-rule', 'Refreshed core result', False)])
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, 'README.md.*referenced capture'):
            self.run_import(self.artifacts / 'refresh-core', partial=True)
        self.assertEqual(self.snapshot(), before)


if __name__ == '__main__':
    unittest.main()
