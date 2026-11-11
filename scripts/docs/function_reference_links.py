"""Validate generated function-reference destinations without executing source."""
from collections import Counter, defaultdict
from html.parser import HTMLParser
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

MARKDOWN_LINK = re.compile(
    r'(?P<image>!?)\[(?P<label>[^\]]*)\]'
    r'\((?P<target><[^>]+>|[^\s)]+)(?:\s+"[^"]*")?\)')
INLINE_CODE = re.compile(r'`[^`\n]*`')
FUNCTION_ANCHOR = re.compile(r'<a\s+(?:id|name)=["\'](fn-[A-Za-z0-9_]+)["\']\s*>\s*</a>')
DECLARATION = re.compile(r'^function ([A-Za-z0-9_]+)\(', re.M)


def without_fenced_code(text):
    """Mask closed or unfinished fences using the renderer's fence rules."""
    fence = ''
    result = []
    for line in text.splitlines(keepends=True):
        marker = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', line.rstrip('\r\n'))
        hidden = bool(fence)
        if marker:
            run, rest = marker.groups()
            if not fence:
                fence = run
                hidden = True
            elif run[0] == fence[0] and len(run) >= len(fence) and not rest.strip():
                fence = ''
        result.append(re.sub(r'[^\n]', ' ', line) if hidden else line)
    return ''.join(result)


def without_inline_code(text):
    """Mask code without moving raw anchors or changing line offsets."""
    return INLINE_CODE.sub(lambda match: ' ' * len(match[0]), text)


def markdown_link_matches(text):
    """Ignore links starting inside literal code, preserving code in labels.

    Match code spans as the reference renderer does. A real link starts before
    the code in [`name`](destination), so its original label stays intact.
    """
    spans = iter(INLINE_CODE.finditer(text))
    span = next(spans, None)
    for match in MARKDOWN_LINK.finditer(text):
        while span is not None and span.end() <= match.start():
            span = next(spans, None)
        if span is None or match.start() < span.start():
            yield match


def markdown_links(text):
    for match in markdown_link_matches(text):
        yield match['image'], match['label'], match['target']


class ReferenceHTML(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = []
        self.links = []
        self.source_links = []
        self.function = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        identifier = attrs.get('id') or (attrs.get('name') if tag == 'a' else None)
        if identifier:
            self.ids.append(identifier)
            if identifier.startswith('fn-'):
                self.function = identifier[3:]
        if tag == 'a' and 'href' in attrs:
            target = attrs['href']
            self.links.append(target)
            if urlsplit(target).path.endswith('.sh') and urlsplit(target).fragment:
                self.source_links.append((self.function, target))


def source_locations(root):
    """Match the generator's top-level declaration inventory, including lines."""
    result = defaultdict(list)
    files = sorted((root / 'lib').rglob('*.sh'))
    entrypoint = root / 'dockistrate.sh'
    if entrypoint.is_file():
        files.append(entrypoint)
    for path in files:
        for line, text in enumerate(path.read_text().splitlines(), 1):
            match = DECLARATION.match(text)
            if match:
                result[match[1]].append((path.resolve(), line))
    return result


def check(root, prose, anchor_lookup):
    """Return reference errors; caches belong to this invocation only."""
    root = Path(root).resolve()
    markdown = root / 'docs/function-reference.md'
    rendered = markdown.with_suffix('.html')
    errors = []
    for path in (markdown, rendered):
        if not path.is_file():
            errors.append(f'{path.relative_to(root)}: missing function reference')
    if errors:
        return errors

    text = prose(markdown.read_text())
    html = ReferenceHTML()
    html.feed(rendered.read_text())
    anchor_text = without_inline_code(text)
    md_ids = re.findall(r'<a\s+(?:id|name)=["\']([^"\']+)', anchor_text)
    md_matches = list(markdown_link_matches(text))
    md_links = [match['target'].strip('<>') for match in md_matches]
    md_source_links = []
    catalog_labels = []
    function = None
    catalog = False
    catalog_functions = []
    link_index = 0
    line_end = 0
    for line in anchor_text.splitlines(keepends=True):
        line_end += len(line)
        if line.rstrip('\r\n') == '## Linked function sources':
            catalog = True
        match = FUNCTION_ANCHOR.search(line)
        if match:
            function = match[1][3:]
            if catalog:
                catalog_functions.append(function)
        while link_index < len(md_matches) and md_matches[link_index].start() < line_end:
            link = md_matches[link_index]
            link_index += 1
            label, target = link['label'], link['target'].strip('<>')
            parts = urlsplit(target)
            if parts.path.endswith('.sh') and parts.fragment:
                md_source_links.append((function, target))
                if catalog:
                    catalog_labels.append((label, target))

    for path, identifiers in ((markdown, md_ids), (rendered, html.ids)):
        for identifier, count in Counter(identifiers).items():
            if count > 1:
                errors.append(f'{path.relative_to(root)}: duplicate anchor {identifier}')
    md_functions = {name for name in md_ids if name.startswith('fn-')}
    html_functions = {name for name in html.ids if name.startswith('fn-')}
    if md_functions != html_functions:
        errors.append('Function reference Markdown/HTML function anchors differ')
    if Counter(md_links) != Counter(html.links):
        errors.append('Function reference Markdown/HTML links differ; regenerate the HTML')
    if Counter(md_source_links) != Counter(html.source_links):
        errors.append('Function reference Markdown/HTML source destinations differ')

    # Markdown links are also checked by the operator-documentation pass. HTML
    # needs its actual IDs, rather than Markdown heading slugs that it lacks.
    html_ids = set(html.ids)
    for target in sorted(set(html.links)):
        parts = urlsplit(target)
        if parts.scheme or parts.netloc:
            if parts.scheme in {'file', 'sandbox'}:
                errors.append(f'{rendered.relative_to(root)}: nonportable link {target}')
            continue
        if target.startswith('/'):
            errors.append(f'{rendered.relative_to(root)}: absolute link {target}')
            continue
        dest = (rendered.parent / unquote(parts.path)).resolve() if parts.path else rendered
        if not dest.is_relative_to(root):
            errors.append(f'{rendered.relative_to(root)}: link escapes repository: {target}')
            continue
        if not dest.exists():
            errors.append(f'{rendered.relative_to(root)}: missing target {target}')
        elif parts.fragment and dest.suffix in {'.md', '.html'}:
            destinations = html_ids if dest == rendered else anchor_lookup(dest)
            if unquote(parts.fragment) not in destinations:
                errors.append(f'{rendered.relative_to(root)}: missing anchor {target}')

    definitions = source_locations(root) if md_source_links or html.source_links else {}
    sources = Counter(function for function, _ in md_source_links)
    for function in catalog_functions:
        if sources[function] != 1:
            errors.append(f'{markdown.relative_to(root)}: fn-{function} needs exactly one source destination')
    for function, target in sorted(set(md_source_links + html.source_links), key=str):
        parts = urlsplit(target)
        if parts.scheme or parts.netloc or parts.path.startswith('/'):
            errors.append(f'Function source must use a relative repository link: {target}')
            continue
        source = (markdown.parent / unquote(parts.path)).resolve()
        if not source.is_relative_to(root):
            errors.append(f'Function source escapes repository: {target}')
            continue
        line = re.fullmatch(r'L([1-9][0-9]*)', unquote(parts.fragment))
        if not function or not line:
            errors.append(f'Invalid function source destination: {target}')
            continue
        locations = definitions.get(function, [])
        if len(locations) != 1:
            errors.append(f'Function source for {function} is missing or ambiguous: {target}')
        elif locations[0] != (source, int(line[1])):
            errors.append(f'Function source line does not declare {function}: {target}')
    for label, target in catalog_labels:
        parts = urlsplit(target)
        source = (markdown.parent / unquote(parts.path)).resolve()
        line = re.fullmatch(r'L([1-9][0-9]*)', unquote(parts.fragment))
        if source.is_relative_to(root) and line:
            expected = f'{source.relative_to(root)}:{line[1]}'
            if label != expected:
                errors.append(f'Function source label does not match its destination: {label} -> {target}')
    return errors
