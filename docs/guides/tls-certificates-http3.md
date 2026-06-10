# TLS, Certificates, and HTTP/3

Dockistrate can generate self-signed certificates, use Let's Encrypt through
Certbot, upload certificate material, and tune TLS behavior globally or per
listener port.

## Common Commands

```text
add-cert <domain> [port_suffix] [selfsigned|letsencrypt|upload] [fullchain] [privkey]
replace-cert <domain> [port_suffix] [selfsigned|letsencrypt|upload] [fullchain] [privkey]
remove-cert <domain> [port_suffix]
list-certs
renew-certs

set-tls-protocols <protocols>
set-tls-ciphers <cipher_string>
set-port-tls-protocols <port> <protocols>
set-port-tls-ciphers <port> <cipher_string>
set-port-http3 <port> <on|off> [auto|off|value]
list-port-http3 [port]
```

## HTTPS Example

Create an HTTPS listener for a stock Nginx backend that serves on container
port 80, with an automatically generated self-signed certificate:

```bash
./dockistrate.sh add-backend example.com nginx:alpine 80 https
./dockistrate.sh start-nginx
./dockistrate.sh check-config
```

For an existing backend, add HTTPS exposure explicitly:

```bash
./dockistrate.sh add-port example.com 443 80 https none
```

When `cert_path` is `none` or `selfsigned`, Dockistrate writes the self-signed
certificate under `state/certs/selfsigned/live/<domain>_<port>`.

## Let's Encrypt

Request or replace a Let's Encrypt certificate:

```bash
./dockistrate.sh add-cert example.com 443 letsencrypt
./dockistrate.sh renew-certs
```

When the proxy is running, Dockistrate uses the Certbot webroot flow and serves
challenges from `/var/www/certbot` inside the proxy container. Port 80 must be
reachable for validation.

## Uploaded Certificates

Upload existing certificate files:

```bash
./dockistrate.sh add-cert example.com 443 upload /path/fullchain.pem /path/privkey.pem
```

Certificate references used by port mappings must stay under the managed
`state/certs` root. Absolute paths outside that root and traversal paths are
blocked.

## TLS Overrides

Set global protocol and cipher preferences:

```bash
./dockistrate.sh set-tls-protocols "TLSv1.2 TLSv1.3"
./dockistrate.sh set-tls-ciphers "HIGH:!aNULL:!MD5"
```

Override a specific HTTPS listener:

```bash
./dockistrate.sh set-port-tls-protocols 443 "TLSv1.3"
./dockistrate.sh set-port-tls-ciphers 443 "ECDHE+AESGCM"
```

Dockistrate validates TLS values with the local OpenSSL build but does not block
intentional operator-selected profiles solely because they are broad or legacy.

## HTTP/3

Enable HTTP/3 for an HTTPS listener:

```bash
./dockistrate.sh set-port-http3 443 on auto
./dockistrate.sh list-port-http3 443
```

HTTP/3 needs UDP published for the same HTTPS listener port. For example, an
HTTPS listener on `443` needs UDP `443`; a listener on `8443` needs UDP `8443`.

## Verification

```bash
./dockistrate.sh list-certs
./dockistrate.sh list-port-http3
./dockistrate.sh status
./dockistrate.sh check-config
openssl s_client -connect localhost:443 -servername example.com
```
