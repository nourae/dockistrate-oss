# Dockistrate documentation

Start with the [README](../README.md), then follow a task below. The guides lead
with interactive steps and keep exact configuration rules in reference sections.
[Navigation](guides/interactive-workflows.md) covers Home, search, input, review,
cancellation, Recent commands, and Favorites.

## Run applications

- [Backends and ports](guides/backends-and-ports.md): create, update, start, stop, and expose applications.
- [Hosts and aliases](guides/hosts-and-aliases.md): share a backend or configure a dedicated hostname.
- [Path routing](guides/path-routing.md): match, rewrite, update, and remove routes.
- [Domain configuration](guides/domain-configuration.md): edit files, validate, preview, and apply.

## Secure traffic

- [Certificates, TLS, and HTTP/3](guides/tls-certificates-http3.md): local and public HTTPS, certificate management, and protocol settings.
- [Mutual TLS](guides/mutual-tls.md): issue, export, revoke, and rotate client identities.
- [Access controls and request rules](guides/access-control-security-rules.md): allowed clients, request conditions, ordering, and inherited defaults.
- [Headers and client addresses](guides/headers-real-ip-hsts-csp.md): headers, HSTS, CSP, forwarded addresses, and trusted proxies.

## Operate and recover

- [Diagnostics, logs, and traffic capture](guides/diagnostics-capture.md): inspect state, investigate requests, and collect traffic.
- [Backups, restore, and cleanup](guides/backups-restore-cleanup.md): protect configuration, recover, and remove resources.
- [Updates](guides/updates.md): back up, preflight, select a release, and verify.

## Advanced settings

- [Nginx and Docker options](guides/advanced-nginx-docker-options.md): directives, images, runtime choices, and visibility.
- [Every interactive command](interactive-command-index.md): a direct link to the procedure for each command.

## Find your menu section

| Menu section | Guide |
| --- | --- |
| Basic Ops | [backends and ports](guides/backends-and-ports.md) · [diagnostics capture](guides/diagnostics-capture.md) · [backups restore cleanup](guides/backups-restore-cleanup.md) |
| Backends | [backends and ports](guides/backends-and-ports.md) |
| Hosts & Aliases | [hosts and aliases](guides/hosts-and-aliases.md) |
| Domain Configuration | [domain configuration](guides/domain-configuration.md) |
| Routing & Ports | [backends and ports](guides/backends-and-ports.md) |
| Advanced Path Routing | [path routing](guides/path-routing.md) |
| Port TLS & HTTP/3 | [tls certificates http3](guides/tls-certificates-http3.md) |
| Bulk Backend Operations | [backends and ports](guides/backends-and-ports.md) |
| Certificates | [tls certificates http3](guides/tls-certificates-http3.md) |
| Clean & Uninstall | [backups restore cleanup](guides/backups-restore-cleanup.md) |
| Backend Headers | [headers real ip hsts csp](guides/headers-real-ip-hsts-csp.md) |
| Logging | [diagnostics capture](guides/diagnostics-capture.md) |
| Backend Protocol & IP Overrides | [advanced nginx docker options](guides/advanced-nginx-docker-options.md) · [headers real ip hsts csp](guides/headers-real-ip-hsts-csp.md) |
| Backend mTLS & Client Certs | [mutual tls](guides/mutual-tls.md) |
| Backend Access Overrides | [access control security rules](guides/access-control-security-rules.md) |
| Access Control & Rules | [access control security rules](guides/access-control-security-rules.md) |
| Diagnostics | [diagnostics capture](guides/diagnostics-capture.md) |
| Updates | [updates](guides/updates.md) |
| Backups & Restore | [backups restore cleanup](guides/backups-restore-cleanup.md) |
| Global Nginx Directives | [advanced nginx docker options](guides/advanced-nginx-docker-options.md) |
| Global Headers & IP | [headers real ip hsts csp](guides/headers-real-ip-hsts-csp.md) |
| Global Access Defaults | [access control security rules](guides/access-control-security-rules.md) |
| Global TLS & Runtime | [advanced nginx docker options](guides/advanced-nginx-docker-options.md) · [tls certificates http3](guides/tls-certificates-http3.md) |
| Traffic Capture | [diagnostics capture](guides/diagnostics-capture.md) |

## Read the examples

Follow named choices rather than menu numbers, which depend on existing state.
Inputs and verification commands are copyable. Screenshots have adjacent short
instructions; shared steps are linked instead of repeated for every action.

An **expected result** describes what to check. A **not live verified** ending
identifies a missing external prerequisite; it is not a successful test result.
The [coverage inventory](interactive-coverage.json) records capture status for
all commands and Home features. [Maintaining these guides](development/interactive-documentation.md)
explains how to reproduce captures and check documentation changes.

## Technical and development reference

- [Function reference](function-reference.md) and [rendered HTML](function-reference.html)
- [Architecture](architecture/dockistrate-flow.md)
- [Threat model](security/threat-model.md) and [security policy](../SECURITY.md)
- [Image maintenance](security/image-maintenance.md)
- [Contributing and validation](../CONTRIBUTING.md)
