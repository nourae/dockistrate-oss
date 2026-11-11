# Dockistrate Traffic Flow

Clients -> reverse proxy (nginx) -> backend containers

```text
Clients                       Reverse Proxy (nginx)                               Backend Containers
+--------------------------+  +-----------------------------------------------+  +---------------------------+
| Client 1: browser        |  | TLS termination (LE/self/custom)              |  | backend-dvwa              |
| dvwa.example.com         |--| Routing: host/alias, port 80 -> 18180         |->| domain: dvwa.example.com  |
| HTTP :80                 |  | Paths, redirects, force HTTPS                 |  | listens: 18180 (HTTP)     |
+--------------------------+  | WebSockets support                            |  | hdrs, mTLS, ACL/IP hdrs   |
                              | HSTS, CSP, ACLs, L7/L3 security rules         |  +---------------------------+
+--------------------------+  | Client/proxy IP headers, aliases              |  +---------------------------+
| Client 2: web/API        |--| TLS: HTTPS/WS 443 -> 8081                     |->| backend-dvws              |
| dvws.example.com         |  | TLS protos/ciphers, HTTP versions             |  | domain: dvws.example.com  |
| HTTPS/WS :443            |  | Access/error logs + custom fields             |  | listens: 8081 (HTTPS/WS)  |
+--------------------------+  | Packet capture, auto backups                  |  | WS enabled, redirects,    |
                              +---------------------------^-------------------+  | mTLS, ACL/IP hdrs         |
                                                          |                      +---------------------------+
                                                          |
+--------------------------+                              |                      +---------------------------+
| Client 3: DB/tooling     |==============================+===================>  | backend-tcp-db            |
| tcp-db.example.com       |                     TCP :5432 passthrough          | domain: tcp-db.example.com |
| TCP :5432                |                                                     | listens: 5432 (TCP)       |
+--------------------------+                                                     | per-backend opts, ACL     |
                                                                                +---------------------------+
```

## Features By Layer

- Clients: pick domain/port; speak HTTP/HTTPS/WS or raw TCP.
- Reverse proxy: TLS termination; HSTS/CSP; redirects/force HTTPS; host aliases; path + port routing; WebSockets; global headers; ACLs + security rules; client/proxy IP headers; TLS protocol/cipher control; access/error logs with custom fields; packet capture; config auto-backups.
- Backends: per-domain images; HTTP/TCP listeners with per-port options; path options; per-backend headers and redirects; mTLS to upstream; per-backend client/proxy IP headers; ACL/security status; Docker opts; host aliases resolve to targets here.

## Legend

- Interactive picker: `./dockistrate.sh -i` (all commands also via CLI flags)
- Domain source: `state/domains/<domain>/config/` (backend declaration, ports, paths, headers, policies, certificates, and inheritance).
- Domain runtime: `runtime/applied/` (last successful source snapshot), `generated/` (Nginx output), `certs/` and `mtls/`, under the same domain folder.
- Shared state: global settings and generated aggregate views under `state/config/`, shared defaults/listeners, `state/logs/` (logs), `state/pcaps/` (captures), and `state/backups/` (snapshots).

Manual edits flow through validation and explicit `apply-domain-config` before
they affect Docker or Nginx. Existing commands immediately update the same
model when their affected domains have no pending edits. Runtime readers use
applied snapshots, so unfinished drafts do not disrupt other domains. See the
[domain configuration guide](../guides/domain-configuration.md).

State schema 5 gives every CSV field names in its first row and complete records
below. Domain identity/settings, shared defaults, and runtime metadata each use
a singleton record; listeners, routes, rules, and Docker arguments use one record
per item. Listener options share their `ports.csv` row, and certificate import
paths share their `certificates.csv` row. `domain.csv` names an alias/dedicated
host target; primary backends and certificate-only domains leave it blank.
Effective-setting reports include provenance columns and a separate
listener table. Explicit `migrate-state` converts older sources and applied
snapshots independently under a recovery journal. It publishes the schema marker
last without activating drafts or restarting services.

Security rules carry an explicit Block, Require, or Allow action. All applicable
Require checks run first; Block/Allow decisions then follow global order, with
the first match deciding. An Allow match only skips later Block/Allow rules.
ACLs and mTLS remain independent requirements. Migration assigns Require to
older rules, preserving their existing behavior.
