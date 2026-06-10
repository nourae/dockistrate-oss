# Diagnostics and Traffic Capture

Use diagnostics commands to inspect runtime state, generated Nginx config,
container status, logs, and packet captures.

## Common Commands

```text
status
status-all
check-config
tail-proxy-logs
list-backends
list-port-mappings
list-log-fields
add-log-field <field> [position]
update-log-field <id> <field>
remove-log-field <id>

start-capture [folder] [--scope all|backends|clients|clients-backends] [--backends "domain..."] [--clients "ip..."] [--tls-decrypt]
stop-capture
```

## Status and Config Checks

```bash
./dockistrate.sh status
./dockistrate.sh status-all
./dockistrate.sh check-config
```

`status` shows the default operator dashboard: proxy/backend state, capture
state, backup posture, headers, TLS overrides, Nginx directives, port mappings,
ACL/security rules, and a host-wide container table.

`status-all` adds details such as access log fields, backend Docker options,
path options, and certificate inventory.

## Logs

Tail proxy logs in one terminal while sending test requests from another:

```bash
# Terminal 1
./dockistrate.sh tail-proxy-logs
```

```bash
# Terminal 2
./dockistrate.sh add-acl example.com l7 allow 127.0.0.1/32
curl -i http://localhost -H 'Host: example.com'
```

Customize access log fields:

```bash
./dockistrate.sh list-log-fields
./dockistrate.sh add-log-field '$request_time'
./dockistrate.sh update-log-field 3 '$upstream_response_time'
./dockistrate.sh remove-log-field 3
```

## Packet Capture

Start a scoped capture:

```bash
./dockistrate.sh start-capture capture-test \
  --scope clients-backends \
  --clients "203.0.113.10" \
  --backends "example.com"
```

Inspect and stop capture:

```bash
./dockistrate.sh status-all
./dockistrate.sh stop-capture
```

Captures and temporary capture state live under `state/pcaps` and `state/tmp`.
Do not commit captures from real environments.

## Verification

```bash
./dockistrate.sh status
./dockistrate.sh check-config
./dockistrate.sh status-all
```

When investigating a live routing issue, prefer Dockistrate status and log
commands first, then fall back to direct Docker commands only for details the
tool does not expose.
