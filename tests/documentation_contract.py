"""Regression cases for missing/incorrect operator documentation evidence."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('documentation_checker', ROOT / 'scripts/docs/check_documentation.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class DocumentationContract(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ('lib/cli', 'docs/guides', 'docs/assets/interactive'):
            (self.root / directory).mkdir(parents=True)
        (self.root / 'lib/cli/interactive_picker_menu_data.sh').write_text('''INTERACTIVE_PICKER_CATEGORIES=("Demo")
function interactive_picker_commands_for_category() { INTERACTIVE_PICKER_CATEGORY_COMMANDS=(demo); }
''')
        self.guide = self.root / 'docs/guides/demo.md'
        self.guide.write_text('# Demo\n\n<a id="cmd-demo"></a>\n\n![Demo screen](../assets/interactive/demo.png)\n')
        image = self.root / 'docs/assets/interactive/demo.png'
        image.write_bytes(b'\x89PNG\r\n\x1a\nPNG fixture')
        transcript = image.with_suffix('.txt')
        transcript.write_text('Observed demo result\n')
        recording = image.with_suffix('.pty.log')
        recording.write_text('Observed demo result\r\n')
        self.provenance = self.root / 'docs/assets/interactive/demo-provenance.json'
        self.provenance.write_text(json.dumps({
            'status': 'passed', 'source_commit': 'a' * 40, 'frames': [{
                'command': 'demo', 'kind': 'result',
                'image': str(image.relative_to(self.root)),
                'transcript': str(transcript.relative_to(self.root)),
                'pty_log': str(recording.relative_to(self.root)), 'pty_byte_offset': 22,
                'image_sha256': hashlib.sha256(image.read_bytes()).hexdigest(),
                'transcript_sha256': hashlib.sha256(transcript.read_bytes()).hexdigest(),
            }]}))
        (self.root / 'README.md').write_text('# Start\n\n[Demo](docs/guides/demo.md#cmd-demo)\n')
        (self.root / 'docs/README.md').write_text('# Docs\n')
        record = {'guide': 'docs/guides/demo.md#cmd-demo', 'screenshots': ['docs/assets/interactive/demo.png'],
                  'verification': 'live-verified', 'evidence': [str(self.provenance.relative_to(self.root))]}
        self.manifest = {'categories': ['Demo'], 'commands': [dict(record, command='demo', category='Demo')],
                         'home': [dict(record, feature=x) for x in ('home', 'search', 'recent', 'favorites',
                                                                   'manual-entry', 'back', 'review', 'cancel', 'help')]}

    def check(self, require_captures=True, public_export=False):
        (self.root / 'docs/interactive-coverage.json').write_text(json.dumps(self.manifest))
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            failed = checker.check(self.root, require_captures=require_captures, public_export=public_export)
        return failed, output.getvalue()

    def add_verification_frame(self, separate_provenance=False):
        image = self.root / 'docs/assets/interactive/verify-http.png'
        image.write_bytes(b'\x89PNG\r\n\x1a\nHTTP verification fixture')
        transcript = image.with_suffix('.txt')
        transcript.write_text('HTTP/1.1 200 OK\n')
        recording = image.with_suffix('.pty.log')
        recording.write_bytes(b'HTTP/1.1 200 OK\r\n')
        record = json.loads(self.provenance.read_text())
        frame = {
            'command': None, 'kind': 'verification',
            'image': str(image.relative_to(self.root)),
            'transcript': str(transcript.relative_to(self.root)),
            'pty_log': str(recording.relative_to(self.root)),
            'pty_byte_offset': recording.stat().st_size,
            'image_sha256': hashlib.sha256(image.read_bytes()).hexdigest(),
            'transcript_sha256': hashlib.sha256(transcript.read_bytes()).hexdigest(),
        }
        provenance = self.provenance
        if separate_provenance:
            provenance = image.with_name('verify-http-provenance.json')
            record['frames'] = [frame]
        else:
            record['frames'].append(frame)
        provenance.write_text(json.dumps(record))
        readme = self.root / 'README.md'
        readme.write_text(readme.read_text() +
                          '\n![HTTP response](docs/assets/interactive/verify-http.png)\n' +
                          '[Captured text](docs/assets/interactive/verify-http.txt)\n')
        return image, transcript, recording, provenance

    def test_complete_documentation(self):
        self.assertEqual(self.check()[0], False)

    def test_missing_image_is_not_complete(self):
        (self.root / 'docs/assets/interactive/demo.png').unlink()
        failed, output = self.check()
        self.assertTrue(failed)
        self.assertIn('missing PNG', output)

    def test_new_menu_command_requires_coverage(self):
        menu = self.root / 'lib/cli/interactive_picker_menu_data.sh'
        menu.write_text(menu.read_text().replace('COMMANDS=(demo)', 'COMMANDS=(demo new-command)'))
        self.assertIn('Menu command has no guide: new-command', self.check()[1])

    def test_expected_result_needs_limitation(self):
        self.manifest['commands'][0]['verification'] = 'not-live-verified'
        self.assertIn('missing verification limitation', self.check()[1])
        self.manifest['commands'][0]['limitation'] = 'A controlled public hostname is unavailable.'
        self.assertFalse(self.check()[0])

    def test_broken_anchor_and_absolute_link(self):
        self.guide.write_text(self.guide.read_text() + '\n[Missing](#missing)\n[Local](/root/private.png)\n')
        output = self.check()[1]
        self.assertIn('missing anchor', output)
        self.assertIn('absolute link', output)

    def test_code_examples_are_not_links(self):
        self.guide.write_text(self.guide.read_text() + '\n```text\n[example](missing.md)\n```\n')
        self.assertFalse(self.check()[0])

    def test_public_mode_checks_documents_outside_the_operator_guides(self):
        (self.root / 'CONTRIBUTING.md').write_text('[Release instructions](docs/absent.md)\n')
        self.assertFalse(self.check()[0], 'Private validation keeps its operator-document scope')
        failed, output = self.check(public_export=True)
        self.assertTrue(failed)
        self.assertIn('CONTRIBUTING.md: missing target docs/absent.md', output)

    def test_public_mode_preserves_command_and_capture_validation(self):
        self.assertFalse(self.check(public_export=True)[0])
        self.manifest['commands'][0]['verification'] = 'pending'
        image = self.root / 'docs/assets/interactive/demo.png'
        image.write_bytes(image.read_bytes() + b'changed')
        failed, output = self.check(public_export=True)
        self.assertTrue(failed)
        self.assertIn('demo: capture still pending', output)
        self.assertIn('image differs from recorded capture hash', output)

    def test_changed_screenshot_requires_new_capture(self):
        with (self.root / 'docs/assets/interactive/demo.png').open('ab') as image:
            image.write(b'changed')
        self.assertIn('image differs from recorded capture hash', self.check()[1])

    def test_verification_image_outside_command_coverage_is_checked(self):
        image, _, _, _ = self.add_verification_frame()
        self.assertFalse(self.check()[0])
        image.write_bytes(image.read_bytes() + b'changed')
        failed, output = self.check()
        self.assertTrue(failed)
        self.assertIn('verify-http.png: image differs from recorded capture hash', output)

    def test_verification_transcript_outside_command_coverage_is_checked(self):
        _, transcript, _, _ = self.add_verification_frame()
        self.assertFalse(self.check()[0])
        transcript.write_text('HTTP/1.1 500 Internal Server Error\n')
        failed, output = self.check()
        self.assertTrue(failed)
        self.assertIn('verify-http.png: transcript differs from recorded capture hash', output)

    def test_verification_only_provenance_is_checked(self):
        image, _, _, _ = self.add_verification_frame(separate_provenance=True)
        self.assertFalse(self.check()[0])
        image.write_bytes(image.read_bytes() + b'changed')
        self.assertIn('verify-http.png: image differs from recorded capture hash', self.check()[1])

    def test_verification_png_signature_is_checked_even_if_hash_matches(self):
        image, _, _, provenance = self.add_verification_frame()
        image.write_bytes(b'not a PNG')
        record = json.loads(provenance.read_text())
        record['frames'][-1]['image_sha256'] = hashlib.sha256(image.read_bytes()).hexdigest()
        provenance.write_text(json.dumps(record))
        self.assertIn('verify-http.png: invalid PNG signature', self.check()[1])

    def test_verification_recording_offset_is_checked(self):
        _, _, recording, provenance = self.add_verification_frame()
        record = json.loads(provenance.read_text())
        record['frames'][-1]['pty_byte_offset'] = recording.stat().st_size + 1
        provenance.write_text(json.dumps(record))
        self.assertIn('verify-http.png: screenshot has no corresponding terminal recording offset',
                      self.check()[1])

    def test_shared_provenance_is_validated_once(self):
        image, _, _, _ = self.add_verification_frame()
        image.write_bytes(image.read_bytes() + b'changed')
        self.assertEqual(self.check()[1].count('verify-http.png: image differs from recorded capture hash'), 1)

    def test_documentation_image_requires_retained_provenance(self):
        self.add_verification_frame()
        record = json.loads(self.provenance.read_text())
        record['frames'].pop()
        self.provenance.write_text(json.dumps(record))
        self.assertIn('screenshot absent from retained capture provenance: '
                      'docs/assets/interactive/verify-http.png', self.check()[1])
        self.assertFalse(self.check(require_captures=False)[0],
                         'The explicit authoring mode may still contain uncaptured screenshots')

    def test_verification_recording_is_required(self):
        _, _, recording, _ = self.add_verification_frame()
        recording.unlink()
        self.assertIn('verify-http.png: missing recorded pty_log', self.check()[1])

    def test_invalid_frame_metadata_is_reported(self):
        _, _, _, provenance = self.add_verification_frame()
        record = json.loads(provenance.read_text())
        record['frames'][-1]['transcript'] = None
        record['frames'][-1]['pty_byte_offset'] = '22'
        provenance.write_text(json.dumps(record))
        output = self.check()[1]
        self.assertIn('verify-http.png: missing recorded transcript', output)
        self.assertIn('verify-http.png: screenshot has no corresponding terminal recording offset', output)

    def test_command_ownership_and_result_checks_remain_required(self):
        image, _, _, _ = self.add_verification_frame()
        self.manifest['commands'][0]['screenshots'] = [str(image.relative_to(self.root))]
        output = self.check()[1]
        self.assertIn('demo: screenshot belongs to another command', output)
        self.assertIn('demo: no captured interactive result', output)

    def test_failed_capture_is_not_verification(self):
        self.provenance.write_text(self.provenance.read_text().replace('"passed"', '"failed"'))
        self.assertIn('capture must be successful', self.check()[1])

    def test_original_recording_must_be_retained(self):
        (self.root / 'docs/assets/interactive/demo.pty.log').unlink()
        self.assertIn('missing recorded pty_log', self.check()[1])

    def test_archived_recording_is_verified_without_extraction(self):
        archive_spec = importlib.util.spec_from_file_location('archive_test_helper',
                       ROOT / 'scripts/docs/capture/evidence_archive.py')
        archive_helper = importlib.util.module_from_spec(archive_spec)
        archive_spec.loader.exec_module(archive_helper)
        recording = self.root / 'docs/assets/interactive/demo.pty.log'
        archive = self.root / 'docs/assets/interactive/demo-recordings.tar.gz'
        metadata = archive_helper.write_archive(archive, {str(recording.relative_to(self.root)): recording.read_bytes()})
        record = json.loads(self.provenance.read_text())
        record['evidence_archive'] = dict(path=str(archive.relative_to(self.root)), **metadata)
        self.provenance.write_text(json.dumps(record))
        recording.unlink()
        self.assertFalse(self.check()[0])
        self.assertFalse(recording.exists(), 'Checking evidence must not extract files')
        with archive.open('ab') as changed:
            changed.write(b'changed')
        self.assertIn('invalid evidence archive', self.check()[1])


class ExportedDocumentationLinks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.readme = self.root / 'README.md'
        self.readme.write_text('# Public documentation\n')

    def check(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            failed = checker.check_export_links(self.root)
        return failed, output.getvalue()

    def test_preflight_needs_no_menu_execution_or_coverage_manifest(self):
        with patch.object(checker, 'menu_inventory', side_effect=AssertionError('Menu must not run')):
            self.assertFalse(self.check()[0])
        result = subprocess.run(['python3', str(ROOT / 'scripts/docs/check_documentation.py'),
                                 '--root', str(self.root), '--export-links-only'],
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_markdown_and_html_use_their_actual_target_anchors(self):
        html = self.root / 'overview.html'
        html.write_text('<section id="release"><a href="README.md#public-documentation">Start</a></section>')
        self.readme.write_text(self.readme.read_text() + '[Release](overview.html#release)\n')
        self.assertFalse(self.check()[0])
        html.write_text('<h1>Release</h1><a href="README.md#absent">Start</a>')
        output = self.check()[1]
        self.assertIn('README.md: missing anchor overview.html#release', output)
        self.assertIn('overview.html: missing anchor README.md#absent', output)

    def test_html_images_and_inline_html_require_targets_and_alt_text(self):
        self.readme.write_text('<img src="missing.png" alt="Screenshot">\n')
        (self.root / 'overview.html').write_text('<img src="README.md"><img src="." alt="Folder">')
        output = self.check()[1]
        self.assertIn('README.md: missing target missing.png', output)
        self.assertIn('overview.html: image needs alt text: README.md', output)
        self.assertIn('overview.html: image target is not a file: .', output)

    def test_reference_style_links_are_validated(self):
        self.readme.write_text('[Read the guide][guide]\n\n[guide]: absent.md "Guide"\n')
        self.assertIn('missing target absent.md', self.check()[1])

    def test_code_examples_are_literal_but_personal_paths_are_still_private(self):
        self.readme.write_text('```markdown\n[Example](absent.md)\n```\n')
        self.assertFalse(self.check()[0])
        for path in ('/Users/operator/work/project', '/home/operator/work/project',
                     '/root/work/project', r'C:\Users\operator\project'):
            with self.subTest(path=path):
                self.readme.write_text('```text\n' + path + '\n```\n')
                self.assertIn('private/local path', self.check()[1])
        self.readme.write_text('```text\n/opt/dockistrate-demo/state\n```\n')
        self.assertFalse(self.check()[0], 'Neutral demo-VM paths remain valid')

    def test_private_repository_and_service_links_are_rejected(self):
        for target in ('https://github.com/nourae/dockistrate.git',
                       'https://github.com/nourae/dockistrate/pull/123',
                       'https://raw.githubusercontent.com/nourae/dockistrate/main/README.md',
                       'https://api.github.com/repos/nourae/dockistrate/contents/README.md',
                       'https://chatgpt.com/codex/security/findings/example',
                       'https://chatgpt.com/codex/cloud/security/runs/example',
                       'https&#58;//github.com/nourae/dockistrate/pull/123'):
            with self.subTest(target=target):
                self.readme.write_text('```text\n' + target + '\n```\n')
                self.assertIn('private service/repository reference', self.check()[1])
        self.readme.write_text('[Public](https://github.com/nourae/dockistrate-oss/pull/123)\n')
        self.assertFalse(self.check()[0])

    def test_nonportable_and_escaping_links_are_rejected(self):
        self.readme.write_text('[Outside](../other.md)\n[Absolute](/opt/example.md)\n'
                               '[Local](file:///opt/example.md)\n[Windows](C:\\work\\example.md)\n')
        output = self.check()[1]
        self.assertIn('link escapes repository', output)
        self.assertIn('absolute link /opt/example.md', output)
        self.assertIn('nonportable link file:///opt/example.md', output)
        self.assertIn('absolute link C:', output)

    def test_source_line_ranges_must_exist(self):
        (self.root / 'example.sh').write_text('# shellcheck shell=bash\nfunction example() { :; }\n')
        self.readme.write_text('[Source](example.sh#L1-L2)\n')
        self.assertFalse(self.check()[0])
        self.readme.write_text('[Missing](example.sh#L3)\n[Reversed](example.sh#L2-L1)\n'
                               '[Zero](example.sh#L0)\n')
        output = self.check()[1]
        self.assertEqual(output.count('missing source line'), 2)
        self.assertIn('invalid source line example.sh#L0', output)

    def test_repeated_html_destinations_share_one_anchor_parse(self):
        (self.root / 'overview.html').write_text('<h1 id="release">Release</h1>')
        self.readme.write_text('[Release](overview.html#release)\n' * 20)
        with patch.object(checker, 'anchors', wraps=checker.anchors) as parse:
            self.assertFalse(self.check()[0])
        self.assertEqual(parse.call_count, 1)

    def test_duplicate_html_destinations_are_rejected(self):
        (self.root / 'overview.html').write_text('<h1 id="release">Release</h1><a name="release"></a>')
        self.assertIn('duplicate anchor release', self.check()[1])

    def test_runtime_directories_are_skipped_without_skipping_source_modules(self):
        (self.root / 'state').mkdir()
        (self.root / 'state/private.md').write_text('[Runtime](missing.md)\n')
        self.assertFalse(self.check()[0])
        (self.root / 'lib/backups').mkdir(parents=True)
        (self.root / 'lib/backups/README.md').write_text('[Missing](absent.md)\n')
        self.assertIn('lib/backups/README.md: missing target absent.md', self.check()[1])

    def test_existing_local_state_is_not_a_valid_published_link_target(self):
        (self.root / 'state').mkdir()
        (self.root / 'state/private.md').write_text('# Private\n')
        self.readme.write_text('[Local state](state/private.md#private)\n')
        self.assertIn('link targets non-exported runtime path', self.check()[1])

    def test_malformed_url_is_reported_as_a_validation_error(self):
        self.readme.write_text('[Malformed](https://[invalid/)\n')
        self.assertIn('invalid link', self.check()[1])

    def test_document_symlink_outside_export_is_rejected(self):
        outside = Path(self.temp.name).with_name(Path(self.temp.name).name + '-external.md')
        outside.write_text('# Outside\n')
        self.addCleanup(outside.unlink)
        (self.root / 'outside.md').symlink_to(outside)
        self.assertIn('outside.md: document escapes repository', self.check()[1])


if __name__ == '__main__':
    unittest.main()
