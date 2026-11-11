"""Exercise reference generation against small source trees, without application setup."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
GRAPH_HEADING = '## Appendix: Command Call Graphs'
CATALOG_HEADING = '## Linked function sources'


class ReferenceGenerationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for directory in ('docs', 'lib/cli', 'scripts'):
            (self.root / directory).mkdir(parents=True)
        for name in ('update-function-reference-appendices.sh', 'render-function-reference-html.sh'):
            shutil.copyfile(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        self.reference = self.root / 'docs/function-reference.md'
        self.manual = '''# Function reference

<a id="fn-run_command"></a>

## Dispatcher

Keep this detailed description and its formatting.

<a id="fn-audit_log"></a>

Audit logging.

<a id="fn-demo_handler"></a>

The demo uses [helper A](#fn-helper_a).

'''
        self.reference.write_text(self.manual + '''## Appendix: Command Call Graphs

### Demo
- `demo` -> [demo_handler](#fn-demo_handler)

## Appendix: Full Command Call Chains

Old generated content.
''')
        (self.root / 'dockistrate.sh').write_text('''function audit_log() {
  :
}
''')
        (self.root / 'lib/cli/run_command.sh').write_text('''function run_command() {
  case "$1" in
  demo)
    demo_handler
    ;;
  esac
}
''')
        self.helpers = self.root / 'lib/helpers.sh'
        self.helpers.write_text('''function demo_handler() {
  helper_z
  helper_a
}
function helper_z() {
  :
}
function helper_a() {
  :
}
''')

    def run_script(self, name, *, success=True):
        # CI resolves bash to macOS Bash 3 for its native portability runs;
        # an explicit binary also allows exercising that shell on Linux.
        shell = os.environ.get('DOCS_TEST_BASH', 'bash')
        result = subprocess.run([shell, str(self.root / 'scripts' / name)], cwd=self.root,
                                text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def generate(self, **kwargs):
        return self.run_script('update-function-reference-appendices.sh', **kwargs)

    def render(self, source):
        self.reference.write_text(source)
        self.run_script('render-function-reference-html.sh')
        return (self.root / 'docs/function-reference.html').read_text()

    def test_catalog_repairs_missing_helpers_and_preserves_manual_entries(self):
        self.generate()
        source = self.reference.read_text()
        self.assertEqual(source.split(GRAPH_HEADING)[0], self.manual)
        catalog = source.split(CATALOG_HEADING)[1]
        self.assertEqual(re.findall(r'<a id="fn-([^"]+)', catalog), ['helper_a', 'helper_z'])
        self.assertIn('[lib/helpers.sh:8](../lib/helpers.sh#L8)', catalog)
        self.assertIn('[lib/helpers.sh:5](../lib/helpers.sh#L5)', catalog)
        self.assertEqual(source.count('id="fn-demo_handler"'), 1)
        anchors = set(re.findall(r'<a id="([^"]+)', source))
        targets = set(re.findall(r'\]\(#(fn-[^)]+)\)', source))
        self.assertFalse(targets - anchors)

    def test_repeated_generation_and_rendering_are_identical(self):
        self.generate()
        first_md = self.reference.read_bytes()
        self.run_script('render-function-reference-html.sh')
        first_html = (self.root / 'docs/function-reference.html').read_bytes()
        self.generate()
        self.run_script('render-function-reference-html.sh')
        self.assertEqual(self.reference.read_bytes(), first_md)
        self.assertEqual((self.root / 'docs/function-reference.html').read_bytes(), first_html)

    def test_new_detailed_entry_replaces_generated_anchor(self):
        self.generate()
        source = self.reference.read_text().replace(GRAPH_HEADING,
                   '<a id="fn-helper_a"></a>\n\nA new detailed entry.\n\n' + GRAPH_HEADING, 1)
        self.reference.write_text(source)
        self.generate()
        source = self.reference.read_text()
        self.assertEqual(source.count('id="fn-helper_a"'), 1)
        self.assertNotIn('id="fn-helper_a"', source.split(CATALOG_HEADING)[1])
        self.assertIn('A new detailed entry.', source.split(GRAPH_HEADING)[0])

    def test_source_line_moves_refresh_the_catalog(self):
        self.generate()
        self.helpers.write_text('# A new introductory comment.\n' + self.helpers.read_text())
        self.generate()
        catalog = self.reference.read_text().split(CATALOG_HEADING)[1]
        self.assertIn('[lib/helpers.sh:9](../lib/helpers.sh#L9)', catalog)
        self.assertNotIn('../lib/helpers.sh#L8', catalog)

    def test_removed_references_do_not_leave_stale_catalog_entries(self):
        self.generate()
        self.helpers.write_text(self.helpers.read_text().replace('  helper_z\n', ''))
        self.generate()
        self.assertNotIn('id="fn-helper_z"', self.reference.read_text())

    def test_code_examples_do_not_require_destinations_or_define_anchors(self):
        examples = """Example: `[literal](#fn-not_a_function)` and `<a id="fn-helper_a"></a>`.

```markdown
[also literal](#fn-not_a_function)
<a id="fn-helper_z"></a>
```

A real [`helper_a`](#fn-helper_a) link remains active.

"""
        self.reference.write_text(self.reference.read_text().replace(
            GRAPH_HEADING, examples + GRAPH_HEADING, 1))
        self.generate()
        catalog = self.reference.read_text().split(CATALOG_HEADING)[1]
        self.assertIn('id="fn-helper_a"', catalog)
        self.assertIn('id="fn-helper_z"', catalog)
        self.assertNotIn('fn-not_a_function', catalog)

    def test_real_code_label_without_source_is_still_rejected(self):
        self.reference.write_text(self.reference.read_text().replace(
            GRAPH_HEADING, '[`missing`](#fn-not_a_function)\n\n' + GRAPH_HEADING, 1))
        original = self.reference.read_bytes()
        self.assertIn('not_a_function; found 0', self.generate(success=False).stderr)
        self.assertEqual(self.reference.read_bytes(), original)

    def test_missing_source_preserves_existing_reference(self):
        self.reference.write_text(self.reference.read_text().replace(
            'The demo uses', '[Missing helper](#fn-not_a_function).\n\nThe demo uses'))
        original = self.reference.read_bytes()
        result = self.generate(success=False)
        self.assertIn('not_a_function; found 0', result.stderr)
        self.assertEqual(self.reference.read_bytes(), original)
        self.assertFalse(list((self.root / 'docs').glob('.function-reference.*')))

    def test_ambiguous_source_preserves_existing_reference(self):
        (self.root / 'lib/duplicate.sh').write_text('function helper_a() { :; }\n')
        original = self.reference.read_bytes()
        result = self.generate(success=False)
        self.assertIn('helper_a; found 2', result.stderr)
        self.assertEqual(self.reference.read_bytes(), original)

    def test_indented_nested_declaration_is_not_a_catalog_source(self):
        self.helpers.write_text(self.helpers.read_text() + '\n  function helper_a() { :; }\n')
        self.generate()
        self.assertIn('[lib/helpers.sh:8](../lib/helpers.sh#L8)', self.reference.read_text())

    def test_named_single_quote_manual_anchor_is_reused(self):
        self.reference.write_text(self.reference.read_text().replace(GRAPH_HEADING,
            "<a name='fn-helper_a'></a>\n\n" + GRAPH_HEADING, 1))
        self.generate()
        self.assertNotIn('id="fn-helper_a"', self.reference.read_text())

    def test_renderer_preserves_code_labels_and_adjacent_links(self):
        rendered = self.render('''# Links

[`helper_a`](#fn-helper_a), [plain](../lib/helpers.sh#L8) and [call `helper_z` now](#fn-helper_z).
''')
        self.assertIn('<a href="#fn-helper_a"><code>helper_a</code></a>', rendered)
        self.assertIn('<a href="../lib/helpers.sh#L8">plain</a>', rendered)
        self.assertIn('<a href="#fn-helper_z">call <code>helper_z</code> now</a>', rendered)
        self.assertEqual(rendered.count('<a href='), 3)

    def test_renderer_escapes_labels_and_keeps_code_links_literal(self):
        rendered = self.render('''# Escaping

[Use `<value>` & inspect](../lib/helpers.sh?x=1&y=2) and `[literal](#no-link)`.
''')
        self.assertIn('<a href="../lib/helpers.sh?x=1&amp;y=2">Use <code>&lt;value&gt;</code> &amp; inspect</a>', rendered)
        self.assertIn('<code>[literal](#no-link)</code>', rendered)
        self.assertEqual(rendered.count('<a href='), 1)

    def test_renderer_keeps_fenced_links_and_anchors_literal(self):
        rendered = self.render("""# Literal example

````markdown
[literal](#fn-not_a_function)
<a id="fn-example"></a>
```
````

[`real`](#fn-real)
""")
        self.assertIn('<pre><code>', rendered)
        self.assertIn('[literal](#fn-not_a_function)', rendered)
        self.assertIn('&lt;a id="fn-example"&gt;&lt;/a&gt;', rendered)
        self.assertNotIn('href="#fn-not_a_function"', rendered)
        self.assertNotIn('<a id="fn-example">', rendered)
        self.assertIn('<a href="#fn-real"><code>real</code></a>', rendered)
        self.assertEqual(rendered.count('<pre><code>'), 1)
        self.assertEqual(rendered.count('</code></pre>'), 1)

    def test_renderer_closes_unfinished_fence_and_preserves_literal_contents(self):
        rendered = self.render('# Literal\n\n~~~text\n[literal](#fn-missing)\n<a id="fn-example"></a>\n')
        self.assertNotIn('href="#fn-missing"', rendered)
        self.assertNotIn('<a id="fn-example">', rendered)
        self.assertIn('&lt;a id="fn-example"&gt;&lt;/a&gt;', rendered)
        self.assertEqual(rendered.count('<pre><code>'), 1)
        self.assertEqual(rendered.count('</code></pre>'), 1)

    def test_renderer_keeps_unclosed_link_and_code_literal(self):
        rendered = self.render('# Incomplete\n\n[missing destination](\n\n`unclosed & <safe>\n')
        self.assertIn('[missing destination](', rendered)
        self.assertIn('`unclosed &amp; &lt;safe&gt;', rendered)
        self.assertNotIn('<a href=', rendered)
        self.assertNotIn('<code>', rendered)


if __name__ == '__main__':
    unittest.main()
