# Advanced Nginx and Docker Options

Advanced options let trusted operators customize proxy images, container runtime
flags, backend Docker runtime flags, and generated Nginx directives.

## Common Commands

```text
set-nginx-image <image[:tag]>
set-nginx-docker-opts <opts>
show-nginx-docker-opts
set-certbot-image <image[:tag]>

set-nginx-directive <scope> [target...] <directive> <value>
set-nginx-directive-raw <scope> [target...] <directive> <value>
remove-nginx-directive <scope> [target...] <directive>
remove-all-nginx-directives [scope...]
list-nginx-directives [scope...]
list-nginx-directive-catalog
set-nginx-directive-strict <on|off>
show-nginx-directive-strict

add-backend <domain> <image> <container_port> <protocol> [--docker-opts opts] [--network net]
update-backend <domain> [--docker-opts opts] [--network net]
```

## Images

Persist the Nginx proxy image:

```bash
./dockistrate.sh set-nginx-image nginx:mainline-alpine
```

Use a one-off startup image while saving the new value:

```bash
./dockistrate.sh start-nginx --nginx-image nginx:mainline-alpine
```

Tag-less image references default to `:latest` for operator overrides. Pinned
defaults are used by fresh Dockistrate configuration.

Set the Certbot image used for ACME issuance:

```bash
./dockistrate.sh set-certbot-image certbot/certbot:v5.2.1
```

## Docker Runtime Options

Persist proxy container options:

```bash
./dockistrate.sh set-nginx-docker-opts '--cpus 1'
./dockistrate.sh show-nginx-docker-opts
./dockistrate.sh set-nginx-docker-opts ''
```

Proxy Docker options reject flags owned by Dockistrate, including container
name, network, published ports, mounts, entrypoint, and removal behavior. Labels
under `com.dockistrate.*` are also reserved.

Backend Docker options are set per backend:

```bash
./dockistrate.sh add-backend example.com nginx:alpine 80 http --docker-opts '-e MODE=preview'
./dockistrate.sh update-backend example.com --docker-opts '-e MODE=stable'
```

Dockistrate rejects backend options that conflict with its container ownership,
network, and cleanup model.

## Nginx Directive Overrides

Use typed directives when possible:

```bash
./dockistrate.sh list-nginx-directive-catalog
./dockistrate.sh set-nginx-directive global client_max_body_size 20m
```

Use raw directives only when the typed catalog does not cover the needed
setting:

```bash
./dockistrate.sh set-nginx-directive-raw backend example.com add_header "X-Env preview"
```

Supported scopes include HTTP global/backend/port/path scopes and stream
global/backend/port scopes. Generic directive strict mode protects directives
owned by specialized commands, such as `server_tokens`, TLS protocols, and TLS
ciphers.

## Verification

```bash
./dockistrate.sh show-nginx-docker-opts
./dockistrate.sh show-nginx-directive-strict
./dockistrate.sh list-nginx-directives all
./dockistrate.sh update-nginx-config
./dockistrate.sh check-config
```
