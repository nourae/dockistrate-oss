# Path Routing

Path options let one backend route different URL prefixes with independent
WebSocket, redirect, header, target, match, priority, and rewrite behavior.

## Common Commands

```text
add-path-option <domain> <nginx_port> <path_prefix> [--ws yes|no|inherit] [--redirect inherit|off|301|302|308] [--headers name|none] [--match prefix|exact|regex] [--priority int] [--target port|host:port] [--rewrite none|strip-prefix|replace:/path] [--reason text] [--loc text]
update-path-option <domain> <nginx_port> <path_prefix> [options]
remove-path-option <domain> <nginx_port> <path_prefix>
remove-all-path-options [domain]
list-path-options [domain] [nginx_port]
```

## Example

Route `/api` to a different upstream port and strip the prefix before proxying:

```bash
./dockistrate.sh add-path-option example.com 80 /api \
  --target 8080 \
  --match prefix \
  --priority 10 \
  --rewrite strip-prefix \
  --reason "API service"
```

List the effective path rows:

```bash
./dockistrate.sh list-path-options example.com 80
```

## Match and Priority

Path prefixes must start with `/` and cannot contain Nginx structure characters
such as `#`, `;`, `{`, or `}`. During config generation, path locations are
inserted before the catch-all `/` route. Lower numeric `--priority` values are
emitted first; when priorities tie, longer path prefixes are emitted first.
Nginx still evaluates each location according to its match mode.

Use `inherit` when a path should keep port-level WebSocket or redirect behavior:

```bash
./dockistrate.sh add-path-option example.com 80 /socket --ws inherit
```

## Header Sets

If a path references a header set, Dockistrate includes the corresponding file
under `state/config/nginx_conf/conf.d/path_headers/` inside that location. This
keeps path-specific headers separate from global or backend headers.

```bash
./dockistrate.sh add-path-option example.com 80 /admin --headers admin-only
```

## Verification

```bash
./dockistrate.sh list-path-options example.com 80
./dockistrate.sh update-nginx-config
./dockistrate.sh check-config
./dockistrate.sh add-acl example.com l7 allow 127.0.0.1/32
curl -i http://localhost/api -H 'Host: example.com'
```

## Cleanup

```bash
./dockistrate.sh remove-path-option example.com 80 /api
./dockistrate.sh remove-all-path-options example.com
```

Removing a port also removes its associated path options.
