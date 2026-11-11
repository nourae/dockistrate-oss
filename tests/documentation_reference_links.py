"""Regression coverage for reference anchors, source destinations, and caching."""
import contextlib
import fnmatch
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


checker = load('reference_documentation_checker', 'scripts/docs/check_documentation.py')
reference = load('reference_links', 'scripts/docs/function_reference_links.py')


class FunctionReferenceLinks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'docs').mkdir()
        (self.root / 'lib').mkdir()
        self.source = self.root / 'lib/demo.sh'
        self.source.write_text('# shellcheck shell=bash\nfunction helper() { :; }\n')
        self.markdown = self.root / 'docs/function-reference.md'
        self.rendered = self.markdown.with_suffix('.html')
        self.markdown.write_text('''# Function reference

<a id="fn-existing"></a>

Existing detailed explanation.

[helper](#fn-helper) and [existing](#fn-existing).

## Linked function sources

<a id="fn-helper"></a>

- `helper` — [lib/demo.sh:2](../lib/demo.sh#L2)
''')
        self.rendered.write_text('''<h1>Function reference</h1>
<a id="fn-existing"></a><p>Existing detailed explanation.</p>
<p><a href="#fn-helper">helper</a> and <a href="#fn-existing">existing</a>.</p>
<h2>Linked function sources</h2>
<a id="fn-helper"></a><ul><li><code>helper</code> — <a href="../lib/demo.sh#L2">lib/demo.sh:2</a></li></ul>
''')

    def check(self):
        return '\n'.join(reference.check(self.root, checker.prose, checker.anchors))

    def replace_both(self, old, new):
        for path in (self.markdown, self.rendered):
            path.write_text(path.read_text().replace(old, new))

    def render_reference(self):
        scripts = self.root / 'scripts'
        scripts.mkdir(exist_ok=True)
        renderer = scripts / 'render-function-reference-html.sh'
        shutil.copy2(ROOT / 'scripts/render-function-reference-html.sh', renderer)
        subprocess.run(['bash', str(renderer)], cwd=self.root, check=True,
                       capture_output=True, text=True)

    def test_renderer_and_checker_ignore_literal_links_inside_code(self):
        self.markdown.write_text(self.markdown.read_text() +
                                 '\nExample: `[literal](#fn-not_a_function)` and '
                                 '`[missing source](../lib/absent.sh#L9)`.\n')
        self.render_reference()
        self.assertIn('<code>[literal](#fn-not_a_function)</code>', self.rendered.read_text())
        self.assertEqual(self.check(), '')

    def test_renderer_and_checker_ignore_raw_anchor_example_in_code(self):
        self.markdown.write_text(self.markdown.read_text() +
                                 '\nExample: `<a id="fn-example"></a>`.\n')
        self.render_reference()
        self.assertEqual(self.check(), '')
        self.assertNotIn('fn-example', checker.anchors(self.markdown))

    def test_renderer_and_checker_ignore_closed_and_unfinished_fences(self):
        source = self.markdown.read_text()
        for closing in ('~~~\n', ''):
            with self.subTest(closing=bool(closing)):
                self.markdown.write_text(source + '\n~~~markdown\n'
                                         '[literal](#fn-not_a_function)\n'
                                         '<a id="fn-example"></a>\n' + closing)
                self.render_reference()
                self.assertEqual(self.check(), '')
                self.assertNotIn('fn-example', checker.anchors(self.markdown))

    def test_renderer_and_checker_keep_real_links_with_code_labels(self):
        self.markdown.write_text(self.markdown.read_text() +
                                 '\n[`helper`](#fn-helper), '
                                 '`[literal](#no-link)`, and [the `existing` helper](#fn-existing).\n')
        self.render_reference()
        self.assertIn('<a href="#fn-helper"><code>helper</code></a>', self.rendered.read_text())
        self.assertEqual(self.check(), '')
        self.replace_both('href="#fn-helper"', 'href="#fn-missing"')
        self.assertIn('missing anchor #fn-missing', self.check())

    def test_valid_catalog_preserves_detailed_entries(self):
        self.assertEqual(self.check(), '')

    def test_missing_html_is_reported(self):
        self.rendered.unlink()
        self.assertIn('missing function reference', self.check())

    def test_missing_anchor_in_both_formats_is_reported(self):
        self.replace_both('<a id="fn-helper"></a>', '')
        self.assertIn('missing anchor #fn-helper', self.check())

    def test_duplicate_anchor_is_reported_in_each_format(self):
        for path in (self.markdown, self.rendered):
            path.write_text(path.read_text() + '\n<a id="fn-helper"></a>\n')
        output = self.check()
        self.assertIn('function-reference.md: duplicate anchor fn-helper', output)
        self.assertIn('function-reference.html: duplicate anchor fn-helper', output)

    def test_html_anchors_must_match_markdown(self):
        self.rendered.write_text(self.rendered.read_text().replace('id="fn-existing"', 'id="fn-old"'))
        self.assertIn('Markdown/HTML function anchors differ', self.check())

    def test_html_links_must_match_markdown_occurrences(self):
        self.rendered.write_text(self.rendered.read_text() + '<a href="#fn-helper">helper</a>')
        self.assertIn('Markdown/HTML links differ', self.check())

    def test_html_source_link_must_belong_to_correct_function(self):
        self.rendered.write_text(self.rendered.read_text().replace(
            '<a id="fn-helper"></a><ul>', '<ul>').replace(
            '</ul>', '</ul><a id="fn-helper"></a>'))
        self.assertIn('Markdown/HTML source destinations differ', self.check())

    def test_stale_source_line_is_reported(self):
        self.source.write_text('\n' + self.source.read_text())
        self.assertIn('source line does not declare helper', self.check())
        self.replace_both('demo.sh#L2', 'demo.sh#L3')
        self.replace_both('demo.sh:2', 'demo.sh:3')
        self.assertEqual(self.check(), '')

    def test_visible_source_line_must_match_link(self):
        self.replace_both('demo.sh:2', 'demo.sh:1')
        self.assertIn('source label does not match its destination', self.check())

    def test_wrong_function_at_recorded_line_is_reported(self):
        self.source.write_text('function other() { :; }\nfunction helper() { :; }\n')
        self.replace_both('demo.sh#L2', 'demo.sh#L1')
        self.assertIn('source line does not declare helper', self.check())

    def test_missing_source_and_ambiguous_declaration_are_reported(self):
        self.source.unlink()
        self.assertIn('missing or ambiguous', self.check())
        self.source.write_text('function helper() { :; }\nfunction helper() { :; }\n')
        self.assertIn('missing or ambiguous', self.check())

    def test_source_must_be_repository_relative(self):
        self.replace_both('../lib/demo.sh#L2', 'https://example.com/lib/demo.sh#L2')
        self.assertIn('relative repository link', self.check())

    def test_source_cannot_escape_repository(self):
        self.replace_both('../lib/demo.sh#L2', '../../demo.sh#L2')
        self.assertIn('source escapes repository', self.check())

    def test_source_requires_valid_one_based_line(self):
        self.replace_both('../lib/demo.sh#L2', '../lib/demo.sh#L0')
        self.assertIn('Invalid function source destination', self.check())

    def test_catalog_entry_requires_a_source_link(self):
        self.markdown.write_text(self.markdown.read_text().replace(
            '[lib/demo.sh:2](../lib/demo.sh#L2)', 'lib/demo.sh:2'))
        self.rendered.write_text(self.rendered.read_text().replace(
            '<a href="../lib/demo.sh#L2">lib/demo.sh:2</a>', 'lib/demo.sh:2'))
        self.assertIn('needs exactly one source destination', self.check())

    def test_html_fragment_checks_use_actual_html_ids(self):
        self.markdown.write_text(self.markdown.read_text() + '\n[Heading](#function-reference)\n')
        self.rendered.write_text(self.rendered.read_text() + '<a href="#function-reference">Heading</a>')
        self.assertIn('function-reference.html: missing anchor #function-reference', self.check())

    def test_nested_generated_stub_is_not_an_ambiguous_top_level_function(self):
        self.source.write_text(self.source.read_text() + '  function helper() { :; }\n')
        self.assertEqual(self.check(), '')


class DocumentationAnchorCaching(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'docs/guides').mkdir(parents=True)
        self.guide = self.root / 'docs/guides/demo.md'
        self.guide.write_text('# Demo\n')
        (self.root / 'README.md').write_text('[Demo](docs/guides/demo.md#demo)\n' * 50)
        (self.root / 'docs/README.md').write_text('# Docs\n')
        features = ('home', 'search', 'recent', 'favorites', 'manual-entry', 'back', 'review', 'cancel', 'help')
        (self.root / 'docs/interactive-coverage.json').write_text(json.dumps({
            'categories': [], 'commands': [],
            'home': [{'feature': feature, 'guide': 'docs/guides/demo.md#demo'} for feature in features],
        }))

    def check(self):
        output = io.StringIO()
        with patch.object(checker, 'menu_inventory', return_value={}):
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                failed = checker.check(self.root, require_captures=False)
        return failed, output.getvalue()

    def test_operator_checks_ignore_links_in_unfinished_fence(self):
        readme = self.root / 'README.md'
        readme.write_text(readme.read_text() + '\n```markdown\n[literal](absent.md)\n')
        self.assertFalse(self.check()[0])

    def test_operator_checks_ignore_literal_code_but_validate_code_labels(self):
        readme = self.root / 'README.md'
        readme.write_text('Example: `[literal](absent.md)`, '
                          '`![literal image](absent.png)`, and '
                          '[`Demo`](docs/guides/demo.md#demo).\n')
        self.assertFalse(self.check()[0])
        readme.write_text(readme.read_text() + '\n[`Missing`](absent.md)\n')
        failed, output = self.check()
        self.assertTrue(failed)
        self.assertIn('missing target absent.md', output)

    def test_repeated_links_share_one_anchor_parse(self):
        with patch.object(checker, 'anchors', wraps=checker.anchors) as anchors:
            self.assertFalse(self.check()[0])
        self.assertEqual(anchors.call_count, 1)

    def test_anchor_cache_does_not_outlive_check_invocation(self):
        self.assertFalse(self.check()[0])
        self.guide.write_text('# Different\n')
        failed, output = self.check()
        self.assertTrue(failed)
        self.assertIn('missing anchor', output)

    def test_real_checkout_cannot_omit_both_reference_files(self):
        (self.root / 'scripts').mkdir()
        (self.root / 'scripts/update-function-reference-appendices.sh').write_text('# fixture\n')
        failed, output = self.check()
        self.assertTrue(failed)
        self.assertIn('function-reference.md: missing function reference', output)
        self.assertIn('function-reference.html: missing function reference', output)

    def test_reference_markdown_participates_in_general_link_checks(self):
        (self.root / 'docs/function-reference.md').write_text('# Reference\n[Missing](absent.md)\n')
        (self.root / 'docs/function-reference.html').write_text('<h1>Reference</h1>')
        failed, output = self.check()
        self.assertTrue(failed)
        self.assertIn('function-reference.md: missing target absent.md', output)


class MarkdownLinkExtraction(unittest.TestCase):
    def test_unclosed_code_delimiter_does_not_hide_real_links(self):
        self.assertEqual(list(reference.markdown_links('Unclosed ` and [real](present.md)')),
                         [('', 'real', 'present.md')])



class DocumentationWorkflowTriggers(unittest.TestCase):
    def assert_source_and_generator_coverage(self, workflow):
        for event in ('pull_request', 'push'):
            with self.subTest(event=event):
                # Stop at the next event, not the deeper-indented paths list.
                lines = workflow.split('  ' + event + ':\n', 1)[1].splitlines()
                patterns, filter_kind = [], None
                for line in lines:
                    if line and not line.startswith('    '):
                        break
                    if line.startswith('    paths:'):
                        filter_kind = 'paths'
                    elif line.startswith('    paths-ignore:'):
                        filter_kind = 'paths-ignore'
                    elif line.startswith('    ') and not line.startswith('      ') and line.strip():
                        if filter_kind is not None:
                            break
                    elif filter_kind and line.startswith('      - '):
                        patterns.append(line.strip()[2:].strip('"\''))
                for changed in ('lib/utils/common.sh', 'lib/cli/review_command.sh',
                                'dockistrate.sh', 'scripts/update-function-reference-appendices.sh',
                                'scripts/render-function-reference-html.sh'):
                    covered = filter_kind is None or filter_kind == 'paths-ignore'
                    for pattern in patterns:
                        negative = pattern.startswith('!')
                        if fnmatch.fnmatchcase(changed, pattern[1:] if negative else pattern):
                            covered = negative if filter_kind == 'paths-ignore' else not negative
                    self.assertTrue(covered, f'{event} omits documentation validation for {changed}')

    def test_source_and_generator_changes_run_documentation_validation(self):
        self.assert_source_and_generator_coverage((ROOT / '.github/workflows/docs-check.yml').read_text())

    def test_events_without_path_filters_cover_every_source_change(self):
        self.assert_source_and_generator_coverage('''on:
  pull_request:
  push:
    branches: [main]
''')

    def test_restrictive_filters_cannot_omit_generators_or_sources(self):
        for filters in ("    paths:\n      - 'docs/**'\n",
                        "    paths:\n      - '**'\n      - '!scripts/**'\n",
                        "    paths-ignore:\n      - 'lib/**'\n"):
            workflow = 'on:\n  pull_request:\n' + filters + '  push:\n' + filters
            with self.assertRaises(AssertionError):
                # Avoid unittest subTest swallowing the expected assertion.
                with patch.object(self, 'subTest', return_value=contextlib.nullcontext()):
                    self.assert_source_and_generator_coverage(workflow)


if __name__ == '__main__':
    unittest.main()
