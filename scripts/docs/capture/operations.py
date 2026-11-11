"""Actual interactive operations, runtime settings, recovery and cleanup journeys."""
import re
import os
import time
import tempfile
import hashlib
from pathlib import Path


def m(pattern):
    return ('menu', pattern)


def t(value, prompt=r': $'):
    return ('text', prompt, value)


def execute(ctx, command, steps=(), *, readonly=False, require=(), after=(), journey=None,
            review_require=()):
    with ctx.ui(journey or command, command=command) as ui:
        ui.command(command)
        for step in steps:
            if step[0] == 'menu':
                ui.menu(step[1], first_match=True)
            else:
                ui.text(step[1], step[2])
        if not readonly:
            ui.menu(r'^Run$', prompt='Review command', require=(re.escape(command), *review_require))
            if command.startswith(('remove-', 'revoke-')) or command in ('clean-all', 'uninstall-all'):
                ui.text(r'Type YES to run this destructive command: ', 'YES')
        for prompt, value in after:
            ui.text(prompt, value)
        result = ui.finish(require=require)
    ctx.proof(command + '-interactive-result', command=command, outcome='command completed without reported error')
    return result


def inspect(ctx):
    for command in ('status', 'status-all', 'check-config'):
        execute(ctx, command, readonly=True, require=('running',) if command == 'status' else ())
    ctx.request('diagnostic-request')
    with ctx.ui('tail-proxy-logs', command='tail-proxy-logs') as ui:
        ui.command('tail-proxy-logs')
        ui.text(r': $', '20')
        output = ui.expect(r'HTTP/1\.[01].*?200[^\r\n]*')
        ctx.capture(ui, 'Observe the application request in proxy logs', output, 'result')
        ui.send('\x03')
        ctx.proof('tail-proxy-logs-observed', command='tail-proxy-logs', outcome='request and 200 response visible; Ctrl-C stops following')


def logs(ctx):
    execute(ctx, 'list-log-fields', readonly=True)
    execute(ctx, 'add-log-field', [t('$request_time'), t('')])
    execute(ctx, 'list-log-fields', readonly=True, require=(r'\$request_time',))
    execute(ctx, 'update-log-field', [m(r'\$request_time'), t('$upstream_response_time')])
    fields = ctx.cli('inspect-field-positions', 'list-log-fields')
    item = re.search(r'^(\d+):.*\$upstream_response_time', fields, re.M)
    if not item:
        raise AssertionError('Updated duration field missing from field list')
    # from/to use the current numbered list, never a saved positional assumption.
    execute(ctx, 'move-log-field', [t(item.group(1)), t('1')])
    ctx.request('log-field-request')
    execute(ctx, 'list-log-fields', readonly=True, require=(r'1:.*\$upstream_response_time',))
    execute(ctx, 'remove-log-field', [m(r'\$upstream_response_time')])
    execute(ctx, 'list-log-fields', readonly=True, journey='log-fields-restored')
    ctx.check_config('logging-config')


def directives(ctx):
    execute(ctx, 'list-nginx-directive-catalog', readonly=True)
    execute(ctx, 'set-nginx-directive', [m(r'^Global \(http\)$'), m(r'^client_max_body_size$'), t('2m')])
    execute(ctx, 'list-nginx-directives', [m(r'^All scopes$')], readonly=True, require=('client_max_body_size', '2m'))
    body = Path('/opt/dockistrate-demo-fixtures/oversized-body.bin')
    body.write_bytes(b'x' * (2 * 1024 * 1024 + 1))
    ctx.request('oversized-body-rejected', expected=413, extra=('--data-binary', '@' + str(body)))
    ctx.request('ordinary-body-limit-unaffected')
    ctx.terminal_command('body-limit-verification', ['curl', '--noproxy', '*', '-sS', '-D', '-',
                         '-o', '/dev/null', '-H', 'Host: example.com', '--data-binary', '@' + str(body),
                         'http://127.0.0.1/'], require=('413',), title='Verify the configured request body limit')
    execute(ctx, 'set-nginx-directive-raw', [m(r'^Global \(http\)$'), m(r'^Enter manually'), t('keepalive_requests'), t('200')])
    execute(ctx, 'show-nginx-directive-strict', readonly=True)
    execute(ctx, 'set-nginx-directive-strict', [m(r'^off(?:\s|$)')])
    execute(ctx, 'show-nginx-directive-strict', readonly=True, require=('off',))
    execute(ctx, 'set-nginx-directive-strict', [m(r'^on(?:\s|$)')], journey='directive-strict-restored')
    ctx.check_config('directive-config')
    ctx.request('directive-response')
    execute(ctx, 'remove-nginx-directive', [m(r'^Global \(http\)$'), m(r'^client_max_body_size')],
            review_require=(r'Directive scope: global', r'Directive name: client_max_body_size'))
    execute(ctx, 'remove-all-nginx-directives', [m(r'^Global \(http\)$')])
    execute(ctx, 'list-nginx-directives', [m(r'^All scopes$')], readonly=True, journey='directives-restored')


def runtime(ctx):
    host = m(r'^example\.com(?:\s|$)')
    execute(ctx, 'set-http-version', [m(r'^http1\.1(?:\s|$)')])
    execute(ctx, 'set-backend-http-version', [host, m(r'^http2(?:\s|$)')])
    ctx.request('http-version-response', https=True)
    version_request = ['curl', '--noproxy', '*', '-ksS', '--http2', '--resolve',
                       'example.com:443:127.0.0.1', '-o', '/dev/null', '-w',
                       'HTTP version: %{http_version}; status: %{http_code}\\n', 'https://example.com/']
    ctx.terminal_command('http2-negotiation', version_request,
                         require=('HTTP version: 2; status: 200',), title='Verify HTTP2 negotiation')
    execute(ctx, 'remove-backend-http-version', [host])
    ctx.terminal_command('http-version-inheritance', version_request,
                         require=('HTTP version: 1.1; status: 200',), title='Verify inherited HTTP1.1')
    execute(ctx, 'show-nginx-docker-opts', readonly=True)
    execute(ctx, 'set-nginx-docker-opts', [m(r'Enter manually'), t('--label docs-example=true'), t('', r'> $')])
    execute(ctx, 'show-nginx-docker-opts', readonly=True, require=('docs-example=true',))
    labels = ctx.run(['docker', 'inspect', '--format', '{{index .Config.Labels "docs-example"}}', 'nginx-proxy'], label='runtime-label')
    if labels.strip() != 'true':
        raise AssertionError('Nginx runtime label was not applied')
    execute(ctx, 'set-nginx-docker-opts', [m(r'Clear')], journey='runtime-options-cleared')
    ctx.cli('fixture-visible-value', 'add-backend-header', ctx.domain, 'response', 'X-Docs-Visibility', 'demo-value')
    execute(ctx, 'set-visibility-policy', [m(r'^Redacted')])
    execute(ctx, 'show-visibility-policy', readonly=True, require=('redacted',))
    execute(ctx, 'status', readonly=True, journey='redacted-status', require=('REDACTED',))
    execute(ctx, 'set-visibility-policy', [m(r'^Full visibility')], journey='visibility-restored')
    execute(ctx, 'status', readonly=True, journey='full-status', require=('demo-value',))
    ctx.cli('fixture-remove-visible-value', 'remove-backend-header', ctx.domain, 'response', 'X-Docs-Visibility')
    for command in ('set-nginx-image', 'set-certbot-image'):
        execute(ctx, command, [m(r'^Use current image:'), m(r'^Refresh latest-tagged')])
    ctx.check_config('runtime-options-config')
    ctx.request('runtime-options-response')


def branches(ctx):
    # Path scope includes the domain, port, and path prompts omitted by Global.
    ctx.cli('fixture-scoped-route', 'add-path-option', ctx.domain, '80', '/limited',
            '--target', '80', '--rewrite', 'strip-prefix')
    scope = [m(r'^Path \(location\)$'), m(r'^example\.com(?:\s|$)'),
             m(r'^80\b'), m(r'^/limited(?:\s|$)')]
    execute(ctx, 'set-nginx-directive', scope + [m(r'^client_max_body_size$'), t('1k')],
            journey='scoped-directive')
    execute(ctx, 'list-nginx-directives', scope, readonly=True,
            require=('client_max_body_size', '1k'), journey='scoped-directive-list')
    body = Path('/opt/dockistrate-demo-fixtures/scoped-body.bin')
    body.write_bytes(b'x' * 2048)
    ctx.request('scoped-limit-rejected', path='/limited/', expected=413,
                extra=('--data-binary', '@' + str(body)))
    # The fixture serves static files: a normal POST reaches it and returns 405.
    ctx.request('scoped-limit-unaffected', expected=405,
                extra=('--data-binary', '@' + str(body)))
    ctx.request('scoped-limit-get', path='/limited/')
    request = ['curl', '--noproxy', '*', '-sS', '-D', '-', '-o', '/dev/null',
               '-H', 'Host: example.com', '--data-binary', '@' + str(body),
               'http://127.0.0.1/limited/']
    ctx.terminal_command('scoped-directive-verified', request, require=('413',),
                         title='Verify the path-specific request body limit')
    execute(ctx, 'remove-nginx-directive', scope + [m(r'^client_max_body_size')],
            journey='scoped-directive-remove',
            review_require=(r'Directive scope: path', r'Domain: example.com',
                            r'Listen port: 80', r'Path prefix: /limited', r'Directive name: client_max_body_size'))
    ctx.request('scoped-limit-removed', path='/limited/', expected=405,
                extra=('--data-binary', '@' + str(body)))
    ctx.terminal_command('scoped-directive-recovered', request, require=('405',),
                         title='Verify the request reaches the application after removal')
    ctx.proof('scoped-directive-outcome', command='set-nginx-directive',
              outcome='2KiB POST rejected only on /limited; GET and root unaffected; removal restores upstream response')
    nginx_image = ctx.run(['docker', 'inspect', '--format', '{{.Config.Image}}',
                           'nginx-proxy'], label='current-proxy-image').strip()
    defaults = (ctx.tool / 'lib/config/common.sh').read_text()
    certbot_image = re.search(r'^DEFAULT_CERTBOT_IMAGE="([^"\n]+)"', defaults, re.M).group(1)
    for command, reference, journey in (
            ('set-nginx-image', nginx_image, 'manual-nginx-image'),
            ('set-certbot-image', certbot_image, 'manual-certbot-image')):
        execute(ctx, command, [m(r'^Enter manually'), t(reference), m(r'^Skip explicit pulls')],
                journey=journey, require=('saved',))
    actual_image = ctx.run(['docker', 'inspect', '--format', '{{.Config.Image}}',
                            'nginx-proxy'], label='manually-selected-proxy-image').strip()
    if actual_image != nginx_image:
        raise AssertionError('Manually selected proxy image was not retained')
    ctx.check_config('manual-image-config')
    ctx.request('manual-image-response')


def backups(ctx):
    execute(ctx, 'set-auto-backups', [m(r'^true(?:\s|$)')])
    execute(ctx, 'set-backup-retention', [t('7')])
    execute(ctx, 'set-backup-compression', [m(r'^true(?:\s|$)')])
    execute(ctx, 'status', readonly=True, journey='backup-settings-status')
    # Disable background backup creation to keep the selected example unambiguous.
    execute(ctx, 'set-auto-backups', [m(r'^false(?:\s|$)')], journey='auto-backups-restored')
    execute(ctx, 'create-backup', [t('before-demo-change')], require=(r'Backup compressed to:',))
    execute(ctx, 'list-backups', readonly=True, require=('before-demo-change',))
    ctx.cli('fixture-change-header', 'add-backend-header', ctx.domain, 'response', 'X-Restore-Example', 'changed')
    ctx.request('before-restore')
    before = (ctx.evidence / 'before-restore.headers').read_text().lower()
    if 'x-restore-example: changed' not in before:
        raise AssertionError('Restore demonstration change did not take effect')
    execute(ctx, 'restore-backup', [m(r'before-demo-change'), t('')], after=((r'\(y/n\): ', 'y'),))
    ctx.check_config('restore-config')
    ctx.request('after-restore')
    after = (ctx.evidence / 'after-restore.headers').read_text().lower()
    if 'x-restore-example:' in after:
        raise AssertionError('Restored request still contains the later header')
    ctx.proof('restore-visible-change', command='restore-backup', outcome='later response header removed by restore')


def repair(ctx):
    execute(ctx, 'fix-default-config')
    execute(ctx, 'fix-permissions', [m(r'^Normalize repository permissions')])
    ctx.check_config('repair-config')
    ctx.request('repair-response')


def updates(ctx):
    execute(ctx, 'help-update', readonly=True)
    # Current checkout's VERSION is a real local release only if that tag exists.
    # Do not fabricate a release tag merely to make preflight succeed.
    version = (ctx.tool / 'VERSION').read_text().strip()
    tags = ctx.run(['git', 'tag', '--list', 'v' + version.lstrip('v')], label='local-version-tag').splitlines()
    if tags:
        tag = tags[0]
        execute(ctx, 'upgrade-preflight', [t(tag), m(r'^Yes$')], readonly=True)
    else:
        # The actual blank target means checking the selected checkout, not a made-up release.
        with ctx.ui('upgrade-preflight', command='upgrade-preflight') as ui:
            ui.command('upgrade-preflight')
            ui.text(r': $', '')
            ui.menu(r'^Yes$')
            ui.finish()
        ctx.proof('preflight-current-checkout', command='upgrade-preflight', outcome='validated current source and saved backup')


def traffic(ctx):
    with ctx.ui('traffic-capture', command='start-capture') as ui:
        ui.command('start-capture')
        ui.text(r': $', 'documentation-example')
        ui.menu(r'^Run$', prompt='Review command')
        ui.menu(r'^Specific backend\(s\)$', prompt='Capture scope')
        ui.text(r'Enter backend domains[^\r\n]*: ', ctx.domain)
        ui.text(r'Enable TLS decrypt capture[^\r\n]*: ', 'n')
        ui.finish()
    for number in range(3):
        ctx.request(f'captured-request-{number}')
    execute(ctx, 'stop-capture')
    captures = sorted((ctx.tool / 'state/pcaps/documentation-example').glob('**/*.pcap*'))
    if not captures:
        raise AssertionError('No packet capture file was produced')
    packets = ctx.run(['tcpdump', '-nn', '-r', str(captures[0]), '-c', '12'], label='captured-packets')
    if not re.search(r'\bIP\b', packets):
        raise AssertionError('Capture contains no observed IP packets')
    ctx.proof('captured-demo-traffic', command='start-capture', outcome='packet records read after generated demo requests')
    ctx.proof('capture-stopped', command='stop-capture', outcome='capture stopped and saved packets readable')
    ctx.terminal_command('packet-inspection', ['tcpdump', '-nn', '-r', str(captures[0]), '-c', '6'],
                         require=(r'IP ',), title='Read the captured demo packets')

    # Exercise the separate TLS-decrypt choice on this disposable daemon. Keep
    # session keys in runtime state; the retained evidence contains only decoded
    # request fields, never key bytes or packet payloads.
    with ctx.ui('tls-traffic-capture', command='start-capture') as ui:
        ui.command('start-capture')
        ui.text(r': $', 'documentation-tls-example')
        ui.menu(r'^Run$', prompt='Review command')
        ui.menu(r'^All Nginx traffic', prompt='Capture scope')
        ui.text(r'Enable TLS decrypt capture[^\r\n]*: ', 'y')
        ui.finish(require=('TLS decrypt capture enabled',))
    ctx.request('captured-https-request', https=True, path='/docs-tls-capture', expected=404,
                extra=('--http1.1',))
    execute(ctx, 'stop-capture', journey='stop-tls-capture', require=('TLS decrypt capture mode disabled',))
    encrypted = sorted((ctx.tool / 'state/pcaps/documentation-tls-example').glob('**/*.pcap*'))
    keys = sorted((ctx.tool / 'state/pcaps/tls-keys').glob('*'))
    keys = [path for path in keys if path.is_file() and path.stat().st_size > 0]
    if not encrypted or not keys:
        raise AssertionError('TLS capture did not retain packets and nonempty session key log')
    # Port443 excludes the cleartext upstream copy, so decoded HTTP here proves
    # the retained key log can decrypt the TLS leg itself.
    # The packaged analyzer may drop elevated privileges. Make owner-only
    # verification copies outside the retained evidence, preserving original
    # capture permissions and never logging packet or key bytes.
    with tempfile.TemporaryDirectory(prefix='dockistrate-capture-verification-') as directory:
        copied = []
        for original, name in ((encrypted[0], 'capture.pcap'), (keys[-1], 'session-keys.log')):
            target = Path(directory) / name
            ctx.run(['sudo', '-n', 'install', '-m', '600', '-o', str(os.getuid()),
                     '-g', str(os.getgid()), str(original), str(target)], label='private-verification-copy')
            copied.append(target)
        ctx.terminal_command('tls-packet-inspection', [
            'tshark', '-r', str(copied[0]), '-o', 'tls.keylog_file:' + str(copied[1]),
            '-Y', 'tcp.port == 443 && http.request', '-T', 'fields',
            '-e', 'http.request.method', '-e', 'http.host', '-e', 'http.request.uri'],
            require=('GET', 'example.com', '/docs-tls-capture'), title='Read the decrypted HTTPS request')
    ctx.proof('tls-capture-verified', command='start-capture',
              outcome='HTTPS request decoded from port443 using retained session keys; keys excluded from artifacts')
    ctx.request('https-after-capture', https=True)


def unrelated_sentinel(ctx):
    # An unmanaged sentinel cannot be created through Dockistrate. It exists only
    # on this empty disposable daemon to test the ownership boundary explicitly.
    ctx.run(['docker', 'run', '-d', '--name', 'docs-unrelated-sentinel', ctx.image], label='unmanaged-sentinel')
    return container_identity(ctx, 'docs-unrelated-sentinel', 'sentinel-before')


def container_identity(ctx, name, label):
    return ctx.run(['docker', 'inspect', '--format',
                    '{{.Id}}|{{.State.Status}}|{{.State.StartedAt}}|{{.RestartCount}}', name], label=label).strip()


def cleanup(ctx):
    sentinel = unrelated_sentinel(ctx)
    ctx.cli('fixture-preserved-backend', 'add-backend', 'preserved.example.com', ctx.image, '80', 'http')
    ctx.cli('fixture-preserved-access', 'set-backend-acl-policy', 'preserved.example.com', 'allow')
    preserved = container_identity(ctx, 'backend-preserved.example.com', 'preserved-backend-before')
    execute(ctx, 'clean-all', [m(r'^example\.com(?:\s|$)')])
    if container_identity(ctx, 'docs-unrelated-sentinel', 'sentinel-after-clean') != sentinel:
        raise AssertionError('Domain cleanup changed an unrelated container')
    remaining = ctx.run(['docker', 'ps', '-a', '--format', '{{.Names}}'], label='resources-after-domain-clean').splitlines()
    if ctx.backend in remaining:
        raise AssertionError('Domain cleanup left its backend container')
    owner = ctx.tool / 'state/domains' / ctx.domain
    if (owner / 'runtime/applied/backend.csv').exists() or (owner / 'runtime/applied/ports.csv').exists():
        raise AssertionError('Domain cleanup left applied backend/listener state')
    if any(path.is_file() for path in (owner / 'certs').glob('**/*')):
        raise AssertionError('Domain cleanup left owned certificates')
    if container_identity(ctx, 'backend-preserved.example.com', 'preserved-backend-after') != preserved:
        raise AssertionError('Single-domain cleanup changed the other configured backend')
    ctx.request('preserved-route-after-cleanup', domain='preserved.example.com')
    ctx.terminal_command('clean-preserved-route', ['curl', '--noproxy', '*', '-sS', '-D', '-', '-o', '/dev/null',
                         '--resolve', 'preserved.example.com:80:127.0.0.1', 'http://preserved.example.com/'],
                         require=('200',), title='Verify the other application still responds')
    ctx.terminal_command('clean-remaining-backends', [ctx.tool / 'dockistrate.sh', 'list-backends'],
                         require=('preserved.example.com',), title='Inspect the remaining backend')
    ctx.proof('cleanup-ownership-boundary', command='clean-all', outcome='unrelated sentinel preserved')


def uninstall(ctx):
    sentinel = unrelated_sentinel(ctx)
    ctx.cli('fixture-uninstall-backup', 'create-backup', 'before-uninstall')
    backup = Path((ctx.tool / 'state/backups/last_full_backup.txt').read_text().strip())
    backup_files = [backup] if backup.is_file() else [path for path in backup.rglob('*') if path.is_file()]
    backup_hashes = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in backup_files}
    if not backup_hashes:
        raise AssertionError('Uninstall prerequisite backup has no files')
    log_marker = ctx.tool / 'state/logs/documentation-preserved.log'
    log_marker.write_text('Retain this demonstration log across uninstall.\n')
    runtime_markers = []
    for folder in ('tmp', 'pcaps', 'acme-webroot'):
        marker = ctx.tool / 'state' / folder / 'documentation-runtime-marker'
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text('Remove this disposable runtime marker.\n')
        runtime_markers.append(marker)
    execute(ctx, 'uninstall-all', [m(r'^Config \+ certs \+ runtime')], after=((r'Type YES to proceed: ', 'YES'),),
            review_require=(r'Uninstall scope: all',))
    remaining = ctx.run(['docker', 'ps', '-a', '--format', '{{.Names}}'], label='resources-after-uninstall').splitlines()
    if 'docs-unrelated-sentinel' not in remaining or 'backend-example.com' in remaining or 'nginx-proxy' in remaining:
        raise AssertionError('Uninstall did not preserve the expected ownership boundary: ' + repr(remaining))
    if container_identity(ctx, 'docs-unrelated-sentinel', 'sentinel-after-uninstall') != sentinel:
        raise AssertionError('Uninstall replaced the unrelated sentinel')
    for filename, digest in backup_hashes.items():
        path = Path(filename)
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise AssertionError('Uninstall changed a retained backup file')
    if log_marker.read_text() != 'Retain this demonstration log across uninstall.\n':
        raise AssertionError('Uninstall changed the retained log')
    if any(marker.exists() for marker in runtime_markers):
        raise AssertionError('Full uninstall left disposable runtime files')
    ctx.terminal_command('uninstall-remaining-containers', ['docker', 'ps', '-a', '--format', '{{.Names}}'],
                         require=('docs-unrelated-sentinel',), title='Verify the unrelated container remains')
    ctx.proof('uninstall-file-retention', command='uninstall-all', backup_files=len(backup_hashes),
              log_preserved=True, runtime_markers_removed=True,
              menu_history_present=(ctx.tool / 'state/config/interactive_recent.csv').is_file())
    ctx.proof('uninstall-ownership-boundary', command='uninstall-all', outcome='owned backend/proxy removed; unrelated sentinel preserved')


GROUPS = {
    'inspect': (inspect, logs),
    'runtime': (directives, runtime),
    'branches': (branches,),
    'backup': (backups, repair, updates),
    'traffic': (traffic,),
    'cleanup': (cleanup,),
    'uninstall': (uninstall,),
}


def run(ctx):
    ctx.ensure_backend()
    selected = os.environ.get('DOCS_OPERATIONS_GROUP', 'all')
    if selected != 'all' and selected not in GROUPS:
        raise ValueError('Unknown operations group: ' + selected)
    for name, journeys in GROUPS.items():
        if selected in ('all', name):
            for journey in journeys:
                journey(ctx)
