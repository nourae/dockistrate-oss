# Headers, Real IP, HSTS, and CSP

Header commands manage global and backend-specific request/response headers,
real client IP forwarding, proxy IP forwarding, HSTS, CSP, and Nginx
`server_tokens`.

## Common Commands

```text
control-server-tokens <on|off>
show-server-tokens

set-client-ip-header <header|off>
set-backend-client-ip-header <domain> <header|off>
remove-backend-client-ip-header <domain>

set-proxy-ip-header <header|off>
set-backend-proxy-ip-header <domain> <header|off>
remove-backend-proxy-ip-header <domain>

add-header <request|response> <name> <value>
update-header <request|response> <name> <value>
remove-header <request|response> <name>
list-headers

add-backend-header <domain> <request|response> <name> <value>
update-backend-header <domain> <request|response> <name> <value>
remove-backend-header <domain> <request|response> <name>
list-backend-headers <domain>

set-hsts <value|off>
set-backend-hsts <domain> <value|off>
set-csp <policy|off>
set-backend-csp <domain> <policy|off>
```

## Header Example

Add a request header with spaces and verify the generated Nginx include quotes
the value:

```bash
./dockistrate.sh add-header request "X-App-Mode" "Preview Enabled"
cat state/config/nginx_conf/conf.d/custom_headers.conf
```

Expected generated directive:

```nginx
proxy_set_header X-App-Mode "Preview Enabled";
```

Header values cannot include control characters, including newlines.
They are fully visible by default in operator-facing output and saved
interactive history. `set-visibility-policy redacted` hides header values from
display, audit, and saved interactive command history without changing the
stored header state or generated Nginx configuration.

## Client IP and Proxy IP

The default client IP header is `X-Forwarded-For`. With that header, Dockistrate
uses `$proxy_add_x_forwarded_for` so the connecting IP is appended. For single-IP
headers such as `X-Real-IP` or `CF-Connecting-IP`, Dockistrate forwards the
resolved trusted client address.

Use a custom proxy IP header when the backend needs to know the direct
connection address:

```bash
./dockistrate.sh set-proxy-ip-header Proxy-IP
```

If trusted proxy ranges are configured, the Nginx `real_ip` module trusts the
configured client IP header. L7/header ACLs and `ip:l7` security selectors use
the resolved `$remote_addr`; L3 ACLs and `ip:l3` selectors use
`$realip_remote_addr`, which preserves the direct/original connection address.
Generated `real_ip` directives are placed before ACL and security rule includes.

## HSTS, CSP, and Tokens

```bash
./dockistrate.sh set-hsts "max-age=31536000; includeSubDomains"
./dockistrate.sh set-csp "default-src 'self'"
./dockistrate.sh control-server-tokens off
```

Backend-specific HSTS, CSP, and header overrides follow the matched server
context, including primary domains, aliases, and dedicated hosts.

## Verification

```bash
./dockistrate.sh list-headers
./dockistrate.sh list-backend-headers example.com
./dockistrate.sh show-server-tokens
./dockistrate.sh update-nginx-config
./dockistrate.sh check-config
```
