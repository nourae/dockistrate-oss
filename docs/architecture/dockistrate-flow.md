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
- Config: `state/config/` (ports, backends, headers, TLS, ACL/security, aliases, nginx_conf)
- Runtime: `state/certs/` (TLS), `state/logs/` (access/error), `state/pcaps/` (captures), `state/backups/` (snapshots)
