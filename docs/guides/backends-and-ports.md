# Backends and Ports

Use backend commands to run application containers and port commands to expose
them through the shared Nginx proxy.

## Common Commands

```text
add-backend <domain> <image> <container_port> <http|https|tcp|udp> [options]
update-backend <domain> [--image img] [--container-port port] [--docker-opts opts] [--network net]
remove-backend [--yes] <domain>
list-backends

add-port <domain> <nginx_port> <container_port> <http|https|tcp|udp> <cert_path|none> [yes|no ws] [--http3 on|off] [--alt-svc auto|off|value]
update-port <domain> [current_port] [--nginx-port port] [--container-port port] [--protocol http|https|tcp|udp] [--cert path|none] [--ws yes|no] [--http3 on|off] [--alt-svc auto|off|value]
remove-port <domain> <nginx_port>
list-port-mappings
```

## Example

Create an HTTP backend and start the proxy:

```bash
./dockistrate.sh add-backend example.com nginx:alpine 80 http
./dockistrate.sh start-nginx
./dockistrate.sh status
```

`add-backend` creates the initial listener unless `--no-expose` is provided. For
HTTP it defaults to port 80; for HTTPS it defaults to port 443 and can mint a
self-signed certificate when no certificate is supplied.

Create a backend without immediate exposure:

```bash
./dockistrate.sh add-backend example.com nginx:alpine 80 http --no-expose
./dockistrate.sh add-port example.com 8080 80 http none
```

Expose TCP or UDP services with the same port commands:

```bash
./dockistrate.sh add-backend tcp.example.com redis:alpine 6379 tcp --no-expose
./dockistrate.sh add-port tcp.example.com 16379 6379 tcp none
```

## WebSockets and Redirects

Use the `ws` flag or dedicated WebSocket commands for HTTP/HTTPS mappings:

```bash
./dockistrate.sh enable-ws example.com 80
./dockistrate.sh disable-ws example.com 80
```

Toggle HTTP-to-HTTPS redirects per HTTP mapping:

```bash
./dockistrate.sh set-port-redirect example.com 80 on 301:443
./dockistrate.sh remove-port-redirect example.com 80
```

## Dedicated Hosts

Dedicated hosts can inherit or override backend-scoped behavior:

```bash
./dockistrate.sh add-dedicated-host app.example.com example.com
./dockistrate.sh set-dedicated-host-inherit app.example.com headers no
./dockistrate.sh list-dedicated-hosts
```

## Verification

```bash
./dockistrate.sh list-backends
./dockistrate.sh list-port-mappings
./dockistrate.sh status
./dockistrate.sh check-config
```

Fresh configs default the ACL policy to `deny`. For a local smoke test, allow
loopback first, then send the expected Host header:

```bash
./dockistrate.sh add-acl example.com l7 allow 127.0.0.1/32
curl -i http://localhost -H 'Host: example.com'
```

## Cleanup

```bash
./dockistrate.sh remove-port example.com 80
./dockistrate.sh remove-backend --yes example.com
```
