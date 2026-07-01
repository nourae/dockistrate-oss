# Dockistrate

Dockistrate is a Bash-based operator tool for running multiple backend
containers behind one Nginx reverse proxy. It manages backend containers, port
exposure, certificates, headers, access controls, diagnostics, backups, and
generated Nginx configuration from a single CLI or interactive picker.

Dockistrate is built for high-privilege infrastructure operators. It preserves
operator flexibility for valid advanced configurations while continuing to
block non-bypassable exploit paths such as unsafe paths, config injection, and
unsafe write/delete operations.

## Documentation

- [Documentation index](docs/README.md)
- [Backends and ports](docs/guides/backends-and-ports.md)
- [TLS, certificates, and HTTP/3](docs/guides/tls-certificates-http3.md)
- [Path routing](docs/guides/path-routing.md)
- [Headers, real IP, HSTS, and CSP](docs/guides/headers-real-ip-hsts-csp.md)
- [Access control and security rules](docs/guides/access-control-security-rules.md)
- [Backups, restore, and cleanup](docs/guides/backups-restore-cleanup.md)
- [Diagnostics and traffic capture](docs/guides/diagnostics-capture.md)
- [Advanced Nginx and Docker options](docs/guides/advanced-nginx-docker-options.md)
- [Function reference](docs/function-reference.md) and
  [HTML function reference](docs/function-reference.html)
- [Threat model](docs/security/threat-model.md)

## Requirements

- Bash. Dockistrate supports macOS Bash 3.2 and GNU Bash.
- Docker. On macOS, install and run
  [Docker Desktop](https://docs.docker.com/desktop/). On Linux, run as a user
  that can access Docker or use `sudo`.
- OpenSSL for certificate and TLS workflows.
- Optional: GNU coreutils on macOS for the full local test timeout helper
  (`gtimeout`).

## Install

Clone the repository and run Dockistrate from the repo root. For production,
check out a release tag instead of tracking `main`:

```bash
git clone https://github.com/nourae/dockistrate-oss.git
cd dockistrate-oss
git fetch --tags --prune origin
git checkout vX.Y.Z
```

Production checkouts are expected to show a detached HEAD at the selected
release tag. That keeps the deployed code pinned and reproducible.

Run Dockistrate with:

```bash
./dockistrate.sh [--version] [-v|--verbose] [-i|--interactive] <command> [args]
```

Use verbose mode when you want commands and logged actions echoed to the
terminal:

```bash
./dockistrate.sh -v status
```

Enable Bash completion:

```bash
source /path/to/dockistrate/completion/dockistrate-completion.bash
```

## Updates

Do not reclone for normal updates. Create a Dockistrate backup first, then
fetch tags, run the read-only preflight, and check out the target release:

```bash
./dockistrate.sh create-backup
git fetch --tags --prune origin
./dockistrate.sh upgrade-preflight --require-backup vX.Y.Z
git checkout vX.Y.Z
./dockistrate.sh upgrade-preflight --require-backup
```

Run `./dockistrate.sh check-config` after checkout if a managed proxy exists.
Production users should stay on release tags and should not use `git pull` as
the update workflow; branch pulls can move a deployment to unreleased changes.
Use `./dockistrate.sh help update` for the workflow reminder. Dockistrate does
not fetch, discover, or apply updates automatically. The target release tag must
match the `VERSION` file in that tag.

## Quick Start

Create a backend, expose it on port 80, start the proxy, and verify generated
configuration:

```bash
./dockistrate.sh add-backend example.com nginx:alpine 80 http
./dockistrate.sh start-nginx
./dockistrate.sh status
./dockistrate.sh check-config
```

The HTTP `add-backend` flow creates the initial port 80 mapping automatically
unless you pass `--no-expose`.

Fresh configs default the ACL policy to `deny`. For a local smoke test, allow
loopback first, then send the expected Host header because Nginx routes by
domain:

```bash
./dockistrate.sh add-acl example.com l7 allow 127.0.0.1/32
curl -i http://localhost -H 'Host: example.com'
```

Remove the sample backend when done:

```bash
./dockistrate.sh remove-backend --yes example.com
./dockistrate.sh remove-nginx
```

## Interactive Mode

Interactive mode keeps common workflows behind a picker so operators can search
commands, choose known domains/ports/certificates, and review arguments before
execution:

```bash
./dockistrate.sh -i
```

Use interactive mode when you want guided prompts. Use CLI mode when scripting
or running in CI.

Routing and certificate prompts prefer menus for known values. For example,
`add-backend` lists common listen/redirect ports, and `update-port` first asks
which existing mapping to change, then reviews the full CLI-equivalent command
after the new ports, protocol, certificate, WebSocket, HTTP/3, and Alt-Svc
choices are selected. Manual entry remains available for custom ports, custom
Alt-Svc values, certificate paths, and upload file paths.

## Common Workflows

| Goal | Start here |
| --- | --- |
| Add, update, or remove backends | [Backends and ports](docs/guides/backends-and-ports.md) |
| Expose HTTP, HTTPS, TCP, UDP, WebSocket, or HTTP/3 ports | [Backends and ports](docs/guides/backends-and-ports.md) |
| Add certificates, renew ACME certificates, or tune TLS | [TLS, certificates, and HTTP/3](docs/guides/tls-certificates-http3.md) |
| Route specific paths to different targets | [Path routing](docs/guides/path-routing.md) |
| Manage request/response headers and real client IP behavior | [Headers, real IP, HSTS, and CSP](docs/guides/headers-real-ip-hsts-csp.md) |
| Configure ACLs and request security rules | [Access control and security rules](docs/guides/access-control-security-rules.md) |
| Back up, restore, clean, uninstall, or repair permissions | [Backups, restore, and cleanup](docs/guides/backups-restore-cleanup.md) |
| Inspect logs, generated configs, runtime status, and packet captures | [Diagnostics and traffic capture](docs/guides/diagnostics-capture.md) |
| Customize Nginx images, Docker runtime options, or directive overrides | [Advanced Nginx and Docker options](docs/guides/advanced-nginx-docker-options.md) |

For the exhaustive command and function inventory, use the
[function reference](docs/function-reference.md).

## Core Commands

```text
start-nginx              Start or recreate the Nginx proxy container
stop-nginx               Stop the proxy container
remove-nginx             Remove the proxy container and anonymous volumes
status                   Show the default operator dashboard
status-all               Show the expanded operator report
check-config             Run nginx -t inside the proxy container
help-update              Show the local release-tag update workflow
upgrade-preflight        Read-only state/tag compatibility check

add-backend              Start a backend and optionally expose an initial port
update-backend           Change image, container port, Docker opts, or network
remove-backend           Remove backend state and its container (--yes for scripts)
list-backends            Show configured backends and exposure summary

add-port                 Add HTTP, HTTPS, TCP, or UDP exposure
update-port              Change an existing port mapping
remove-port              Remove a port mapping
list-port-mappings       List configured listener mappings

add-cert                 Generate or upload certificate material
renew-certs              Renew eligible Let's Encrypt certificates
create-backup            Snapshot state/config
restore-backup           Restore a safe backup archive or backup name
uninstall-all            Remove Dockistrate-managed runtime state by scope
```

## Validation

Run the regression suite before release candidates or behavior changes:

```bash
./tests/run.sh
```

The suite uses lightweight Docker mocks and `SKIP_DOCKER_CHECKS=true` behavior.
It checks generated artifacts such as backend state, Nginx configs, TLS
overrides, ACL/security-rule includes, headers, mTLS directives, and packet
capture helpers.

## Security Model

Dockistrate assumes a trusted, high-privilege operator. It does not try to
prevent every risky but intentional admin choice, such as weak TLS settings or
advanced Docker options. It does enforce exploit-prevention controls around
config generation, state files, paths, headers, certificates, and cleanup.

Runtime material lives under `state/`, including generated config, certs,
backups, logs, packet captures, and temporary files. Do not commit private keys,
real certificates, logs, captures, or runtime state from production systems.
The active `state/` root and its runtime subdirectories must be real
directories; Dockistrate rejects symlinked runtime roots before writing,
logging, or normalizing permissions.
Docker option and header values are fully visible by default in operator-facing
output and saved interactive history. Use
`./dockistrate.sh set-visibility-policy redacted` when shared terminals or
support transcripts should hide those values in display, audit, and saved
interactive command history; stored state and generated runtime configuration
still retain the real values.
The current backend and port state header is
`record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location`.

## Non-Affiliation

Dockistrate is independent and is not affiliated with, endorsed by, or sponsored by Docker, F5, NGINX, Certbot, Let’s Encrypt, or any other third-party tool or service it invokes or integrates with.

## Contributing

Keep user-facing surfaces in sync when behavior changes: CLI dispatch,
interactive prompts, completion, README/docs, and generated function-reference
outputs. Runtime changes should include focused tests under `tests/` or
`tests/integration/`.

Docs-only changes should state that no runtime behavior changed.

## License

See [LICENSE](LICENSE).
