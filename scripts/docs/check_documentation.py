#!/usr/bin/env python3
"""Check the operator documentation and its menu-to-guide coverage (stdlib only)."""
import argparse
from collections import Counter
import hashlib
from html import unescape
from html.parser import HTMLParser
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2]
RUNTIME_DOCUMENT_ROOTS = {'.git', 'state', 'tmp', 'logs', 'certs', 'backups',
                          'captures', 'acme-webroot', 'apps'}

reference_spec = importlib.util.spec_from_file_location(
    'function_reference_links', Path(__file__).with_name('function_reference_links.py'))
reference_tools = importlib.util.module_from_spec(reference_spec)
reference_spec.loader.exec_module(reference_tools)


def menu_inventory(root):
    script = '''source lib/cli/interactive_picker_menu_data.sh
for category in "${INTERACTIVE_PICKER_CATEGORIES[@]}"; do
  interactive_picker_commands_for_category "$category"
  for command in "${INTERACTIVE_PICKER_CATEGORY_COMMANDS[@]}"; do
    printf '%s\\t%s\\n' "$category" "$command"
  done
done'''
    output = subprocess.check_output(['bash', '-c', script], cwd=root, text=True)
    result = {}
    for line in output.splitlines():
        category, command = line.split('\t')
        result.setdefault(command, category)
    return result


def prose(source):
    return reference_tools.without_fenced_code(source)


class DocumentHTML(HTMLParser):
    """Collect actual HTML destinations, including inline HTML in Markdown."""
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = []
        self.links = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        identifier = attrs.get('id') or (attrs.get('name') if tag == 'a' else None)
        if identifier:
            self.ids.append(identifier)
        if tag in {'a', 'link'} and attrs.get('href') is not None:
            self.links.append((False, '', attrs['href']))
        if tag in {'img', 'script', 'source', 'video', 'audio', 'iframe'} and attrs.get('src') is not None:
            self.links.append((tag == 'img', attrs.get('alt', ''), attrs['src']))
        if tag == 'video' and attrs.get('poster') is not None:
            self.links.append((False, '', attrs['poster']))


def anchors(path):
    if path.suffix.lower() in {'.html', '.htm'}:
        document = DocumentHTML()
        document.feed(path.read_text())
        return set(document.ids)
    text = prose(path.read_text())
    anchor_text = reference_tools.without_inline_code(text)
    document = DocumentHTML()
    document.feed(anchor_text)
    found = set(document.ids)
    seen = {}
    for heading in re.findall(r'^#{1,6}\s+(.+?)\s*#*$', text, flags=re.M):
        heading = re.sub(r'<[^>]+>', '', heading).lower()
        slug = re.sub(r'[^\w\- ]', '', heading).replace(' ', '-')
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        found.add(slug + (f'-{count}' if count else ''))
    return found


def exported_documents(root):
    """Inspect every shipped document without traversing runtime or Git state."""
    files = []
    for directory, children, names in os.walk(root, followlinks=False):
        if Path(directory) == root:
            children[:] = [name for name in children if name not in RUNTIME_DOCUMENT_ROOTS]
        for name in names:
            path = Path(directory) / name
            if path.suffix.lower() in {'.md', '.markdown', '.html', '.htm'}:
                files.append(path)
    return sorted(files)


def check_document_links(root, files, anchor_lookup, *, public_export=False,
                         require_captures=False, recorded_images=frozenset()):
    """Validate local destinations with invocation-scoped anchor/line caches."""
    errors = []
    line_counts = {}
    private_url = re.compile(
        r'(?:https?:)?//(?:(?:github\.com|raw\.githubusercontent\.com)/nourae/'
        r'dockistrate(?:\.git)?(?=[/?#\s<>\"\')]|$)|api\.github\.com/repos/nourae/'
        r'dockistrate(?=[/?#\s<>\"\')]|$)|chatgpt\.com/codex/'
        r'(?:tasks?/|security/findings/|cloud/security/(?:runs|findings)/))', re.I)
    local_path = re.compile(r'(?:/(?:root|Users|home)/|/private/var/folders/|'
                            r'[A-Za-z]:[\\/]Users[\\/]|\.codex/(?:visualizations|worktrees))')
    for file in files:
        relative = file.relative_to(root)
        if not file.resolve().is_relative_to(root):
            errors.append(f'{relative}: document escapes repository')
            continue
        try:
            source = file.read_text()
        except (OSError, UnicodeError) as error:
            errors.append(f'{relative}: unreadable document: {error}')
            continue
        is_html = file.suffix.lower() in {'.html', '.htm'}
        text = source if is_html else prose(source)
        document = DocumentHTML()
        document.feed(text if is_html else reference_tools.without_inline_code(text))
        links = list(document.links)
        if not is_html:
            links.extend(reference_tools.markdown_links(text))
            # Reference-style destinations also need checking when not inline.
            for match in re.finditer(r'^ {0,3}\[[^\]\n]+\]:\s*(<[^>]+>|\S+)', text, re.M):
                links.append((False, '', match[1]))
        if public_export:
            for identifier, count in Counter(document.ids).items():
                if count > 1:
                    errors.append(f'{relative}: duplicate anchor {identifier}')
        for image, label, raw in links:
            target = raw.strip('<>')
            try:
                parts = urlsplit(target)
            except ValueError:
                errors.append(f'{relative}: invalid link {target}')
                continue
            if image and not label.strip():
                errors.append(f'{relative}: image needs alt text: {target}')
            if re.match(r'^[A-Za-z]:[\\/]', unquote(target)):
                errors.append(f'{relative}: absolute link {target}')
                continue
            if parts.scheme or parts.netloc:
                if parts.scheme.lower() in {'file', 'sandbox', 'vscode', 'codex'}:
                    errors.append(f'{relative}: nonportable link {target}')
                continue
            if target.startswith('/'):
                errors.append(f'{relative}: absolute link {target}')
                continue
            dest = (file.parent / unquote(parts.path)).resolve() if parts.path else file.resolve()
            if not dest.is_relative_to(root):
                errors.append(f'{relative}: link escapes repository: {target}')
                continue
            if (public_export and dest != root
                    and dest.relative_to(root).parts[0] in RUNTIME_DOCUMENT_ROOTS):
                errors.append(f'{relative}: link targets non-exported runtime path: {target}')
                continue
            if not dest.exists():
                errors.append(f'{relative}: missing target {target}')
            elif image and not dest.is_file():
                errors.append(f'{relative}: image target is not a file: {target}')
            elif parts.fragment and dest.suffix.lower() in {'.md', '.markdown', '.html', '.htm'}:
                if unquote(parts.fragment) not in anchor_lookup(dest):
                    errors.append(f'{relative}: missing anchor {target}')
            elif public_export and parts.fragment and dest.is_file():
                fragment = unquote(parts.fragment)
                line = re.fullmatch(r'L([1-9][0-9]*)(?:-L([1-9][0-9]*))?', fragment)
                if fragment.startswith('L') and not line:
                    errors.append(f'{relative}: invalid source line {target}')
                elif line:
                    if dest not in line_counts:
                        line_counts[dest] = len(dest.read_bytes().splitlines())
                    first, last = int(line[1]), int(line[2] or line[1])
                    if first > last or last > line_counts[dest]:
                        errors.append(f'{relative}: missing source line {target}')
            if (require_captures and image and dest.is_relative_to(root / 'docs/assets/interactive')
                    and dest not in recorded_images):
                errors.append(f'{relative}: screenshot absent from retained capture provenance: {target}')
        # Exported code examples are published text too. Keep default private
        # checks scoped to operator prose, as before.
        visible = unquote(unescape(source)) if public_export else text
        if local_path.search(visible):
            errors.append(f'{relative}: private/local path in operator documentation')
        if public_export and private_url.search(visible):
            errors.append(f'{relative}: private service/repository reference in public documentation')
        if require_captures and '<!-- screenshots:' in text:
            errors.append(f'{relative}: unfinished screenshot insertion marker')
    return errors


def check_export_links(root):
    """Read-only export preflight; no menu execution or capture manifest needed."""
    root = root.resolve()
    files = exported_documents(root)
    anchor_cache = {}

    def cached_anchors(path):
        path = path.resolve()
        if path not in anchor_cache:
            anchor_cache[path] = anchors(path)
        return anchor_cache[path]

    errors = check_document_links(root, files, cached_anchors, public_export=True)
    print(f'Checked links and public references in {len(files)} exported documents.')
    for error in errors:
        print(f'ERROR: {error}', file=sys.stderr)
    return bool(errors)


def check_capture_provenance(root, path, archive_cache, errors):
    """Validate every retained frame, including verification-only journeys."""
    reference = path.relative_to(root)
    try:
        record = json.loads(path.read_text())
        if not isinstance(record, dict) or not isinstance(record.get('frames'), list):
            raise ValueError('Capture provenance must contain a frames list')
    except (ValueError, OSError) as error:
        errors.append(f'{reference}: unreadable capture provenance: {error}')
        return {}
    commit = record.get('source_commit')
    if record.get('status') != 'passed' or not isinstance(commit, str) or not re.fullmatch(r'[a-f0-9]{40}', commit):
        errors.append(f'{reference}: capture must be successful and pinned to a source revision')
    archived = record.get('evidence_archive')
    members = None
    if archived is not None:
        members = {}
        try:
            if (not isinstance(archived, dict) or not isinstance(archived.get('path'), str)
                    or not isinstance(archived.get('sha256'), str) or not isinstance(archived.get('members'), dict)):
                raise ValueError('Invalid evidence archive metadata')
            archive_path = (root / archived['path']).resolve()
            if not archive_path.is_relative_to(root):
                raise ValueError('Archive path escapes repository')
            # Distinct metadata for the same archive must not reuse a successful check.
            key = (archive_path, archived['sha256'], json.dumps(archived['members'], sort_keys=True))
            if key not in archive_cache:
                archive_cache[key] = {}
                spec = importlib.util.spec_from_file_location('documentation_evidence_archive',
                       Path(__file__).parent / 'capture/evidence_archive.py')
                helper = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(helper)
                data = helper.read_archive(archive_path, expected_archive_sha256=archived['sha256'])
                if set(data) != set(archived['members']):
                    raise ValueError('Archive member inventory differs from provenance')
                for member, content in data.items():
                    metadata = archived['members'][member]
                    if not isinstance(metadata, dict) or hashlib.sha256(content).hexdigest() != metadata.get('sha256'):
                        raise ValueError('Archive member differs from recorded hash: ' + member)
                    if re.search(rb'-----BEGIN (?:[A-Z ]*PRIVATE KEY|CERTIFICATE)-----', content):
                        raise ValueError('Certificate/key material in retained evidence: ' + member)
                archive_cache[key] = data
            members = archive_cache[key]
        except (ValueError, OSError) as error:
            errors.append(f'{reference}: invalid evidence archive: {error}')
    frames = {}
    for index, frame in enumerate(record['frames']):
        if not isinstance(frame, dict) or not isinstance(frame.get('image'), str) or not frame['image']:
            errors.append(f'{reference}: frame {index + 1} has no image path')
            continue
        image = frame['image']
        if image in frames:
            errors.append(f'{reference}: duplicate captured image: {image}')
        frames[image] = frame
        for field in ('image', 'transcript', 'pty_log'):
            name = frame.get(field)
            if not isinstance(name, str) or not name:
                errors.append(f'{image}: missing recorded {field}')
                continue
            if field == 'pty_log' and members is not None:
                data = members.get(name)
                if data is None:
                    errors.append(f'{image}: missing archived pty_log')
                    continue
            else:
                asset = (root / name).resolve()
                if not asset.is_relative_to(root) or not asset.is_file():
                    errors.append(f'{image}: missing recorded {field}')
                    continue
                try:
                    data = asset.read_bytes()
                except OSError as error:
                    errors.append(f'{image}: unreadable recorded {field}: {error}')
                    continue
            if field in ('image', 'transcript') and hashlib.sha256(data).hexdigest() != frame.get(field + '_sha256'):
                errors.append(f'{image}: {field} differs from recorded capture hash')
            if field == 'image' and not data.startswith(b'\x89PNG\r\n\x1a\n'):
                errors.append(f'{image}: invalid PNG signature')
            offset = frame.get('pty_byte_offset')
            if field == 'pty_log' and (type(offset) is not int or not 0 < offset <= len(data)):
                errors.append(f'{image}: screenshot has no corresponding terminal recording offset')
    return frames


def check(root, require_captures=True, public_export=False):
    root = root.resolve()
    errors = []
    manifest_path = root / 'docs/interactive-coverage.json'
    manifest = json.loads(manifest_path.read_text())
    inventory = menu_inventory(root)
    rows = manifest['commands']
    ids = [row['command'] for row in rows]
    if len(set(ids)) != len(ids):
        errors.append('Duplicate command rows in coverage inventory')
    for command in sorted(set(inventory) - set(ids)):
        errors.append(f'Menu command has no guide: {command}')
    for command in sorted(set(ids) - set(inventory)):
        errors.append(f'Coverage refers to absent menu command: {command}')
    if set(manifest['categories']) != set(inventory.values()):
        errors.append('Coverage category list differs from the current menu')
    required_home = {'home', 'search', 'recent', 'favorites', 'manual-entry', 'back', 'review', 'cancel', 'help'}
    if {r['feature'] for r in manifest['home']} != required_home:
        errors.append('Home/navigation coverage must include all nine navigation features')
    provenance_cache = {}
    archive_cache = {}
    recorded_images = set()
    anchor_cache = {}

    def cached_anchors(path):
        path = path.resolve()
        if path not in anchor_cache:
            anchor_cache[path] = anchors(path)
        return anchor_cache[path]

    def capture_frames(reference, name):
        path = (root / reference).resolve()
        if not path.is_relative_to(root) or not path.is_file() or path.suffix != '.json':
            errors.append(f'{name}: missing capture provenance {reference}')
            return {}
        if path not in provenance_cache:
            frames = check_capture_provenance(root, path, archive_cache, errors)
            provenance_cache[path] = frames
            recorded_images.update((root / image).resolve() for image in frames)
        return provenance_cache[path]

    # Verification screenshots need not appear in command/navigation coverage.
    # Check the complete retained capture inventory before checking those rows.
    for path in sorted((root / 'docs/assets/interactive').rglob('*-provenance.json')):
        capture_frames(path.relative_to(root), path.name)
    for row in rows + manifest['home']:
        name = row.get('command', row.get('feature'))
        guide, sep, anchor = row['guide'].partition('#')
        target = root / guide
        if not target.is_file():
            errors.append(f'{name}: missing guide {guide}')
        elif not sep or anchor not in cached_anchors(target):
            errors.append(f'{name}: missing guide anchor {row["guide"]}')
        if row.get('command') and row['category'] != inventory.get(name):
            errors.append(f'{name}: wrong category')
        status = row.get('verification', 'pending')
        if status not in {'live-verified', 'not-live-verified', 'pending'}:
            errors.append(f'{name}: unknown verification status {status}')
        if require_captures:
            if status == 'pending':
                errors.append(f'{name}: capture still pending')
            if not row.get('screenshots'):
                errors.append(f'{name}: no captured screens')
            if status == 'not-live-verified' and not row.get('limitation'):
                errors.append(f'{name}: missing verification limitation')
            if status == 'live-verified' and not row.get('evidence'):
                errors.append(f'{name}: missing verification evidence')
        for image in row.get('screenshots', []):
            path = root / image
            if not path.is_file() or path.suffix.lower() != '.png':
                errors.append(f'{name}: missing PNG {image}')
        frames = {}
        for reference in row.get('evidence', []):
            frames.update(capture_frames(reference, name))
        if row.get('evidence'):
            for image in row.get('screenshots', []):
                frame = frames.get(image)
                if not frame:
                    errors.append(f'{name}: screenshot absent from capture provenance: {image}')
                    continue
                if row.get('command') and frame.get('command') != name:
                    errors.append(f'{name}: screenshot belongs to another command: {image}')
            if row.get('command') and not any(frames.get(image, {}).get('kind') == 'result'
                                              for image in row.get('screenshots', [])):
                errors.append(f'{name}: no captured interactive result')
    files = [root / 'README.md', root / 'docs/README.md'] + sorted((root / 'docs/guides').glob('*.md'))
    for optional in ('docs/interactive-command-index.md', 'docs/development/interactive-documentation.md',
                     'docs/function-reference.md'):
        if (root / optional).exists():
            files.append(root / optional)
    if public_export:
        files = exported_documents(root)
    errors.extend(check_document_links(root, files, cached_anchors, public_export=public_export,
                                      require_captures=require_captures, recorded_images=recorded_images))
    # Small operator-only fixtures need not contain an implementation reference.
    # A real checkout (or either half of the reference pair) requires both files.
    if any((root / path).exists() for path in (
            'scripts/update-function-reference-appendices.sh',
            'docs/function-reference.md', 'docs/function-reference.html')):
        errors.extend(reference_tools.check(root, prose, cached_anchors))
    print(f'Checked {len(inventory)} commands, {len(manifest["categories"])} categories, '
          f'{len(manifest["home"])} navigation features, {len(files)} documents and '
          f'{sum(len(frames) for frames in provenance_cache.values())} retained capture frames.')
    for error in errors:
        print(f'ERROR: {error}', file=sys.stderr)
    return bool(errors)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--allow-pending-captures', action='store_true', help='Authoring only; CI requires captures')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--public-export', action='store_true',
                      help='Check coverage/evidence and every exported Markdown/HTML document')
    mode.add_argument('--export-links-only', action='store_true',
                      help='Read-only export preflight: all document links/privacy, without menu execution')
    args = parser.parse_args()
    if args.export_links_only:
        return check_export_links(args.root.resolve())
    return check(args.root.resolve(), not args.allow_pending_captures, args.public_export)


if __name__ == '__main__':
    sys.exit(main())
