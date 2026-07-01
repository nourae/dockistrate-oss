# Access Control and Security Rules

Dockistrate supports IP-based ACLs and request security rules that render into
generated Nginx includes. Use ACLs for allow/deny policy and security rules for
request predicates such as headers, methods, cookies, query strings, and paths.

## Common Commands

```text
set-acl-policy <allow|deny>
set-acl-status <code>
set-security-rule-status <code>
set-trusted-proxies <cidr_list|none>
set-real-ip-recursive <on|off>

add-acl <domain> <l7|l3|both> <allow|deny> <ip|CIDR-for-l7...> [status_code]
remove-acl <id>
disable-acl <id>
enable-acl <id>
update-acl <id> [--domain d] [--scope l7|l3|both] [--action allow|deny] [--ip ip|CIDR-for-l7] [--code status]
list-acl

add-security-rule <domain> <count> (<field_type> <name|-> <condition> <value|->)x<count> [--mode and|or] [--code status]
update-security-rule <id> [--domain domain] [--mode and|or] [--code status] [--reason text] [--loc text] [--count n (<field_type> <name|-> <condition> <value|->)x<n>]
set-security-rule-mode <id> <and|or>
remove-security-rule <id>
list-security-rules

set-backend-acl-status <domain> <code>
set-backend-security-rule-status <domain> <code>
```

ACL and security-rule IP selectors are IPv4-only. CIDR ranges are accepted only
for `l7` ACL rows. Use exact IPv4 addresses for `l3` or `both`; `update-acl`
applies the same rule based on the resulting scope.

## ACL Example

Block unmatched client IPs and allow a trusted network:

```bash
./dockistrate.sh set-acl-policy deny
./dockistrate.sh add-acl example.com l7 allow 203.0.113.0/24
./dockistrate.sh list-acl
```

Trusted proxy ranges configure Nginx real-IP trust; they do not create ACL allow
rows. With ACL policy `deny`, proxy health checks or proxy-originated traffic
still need explicit ACL allow rows. Header-based ACL behavior only applies to
requests that arrive through trusted proxies.

## Security Rule Examples

Security-rule conditions describe allowed traffic. Dockistrate returns the
configured status when the condition fails. To block a suspicious user agent,
require that the header does not contain it:

```bash
./dockistrate.sh add-security-rule example.com 1 \
  header User-Agent not_contains "bad-client" --code 403
```

Grouped rules use the same pass-requirement model: `and` returns the configured
status unless all conditions pass, while `or` returns it unless at least one
condition passes. Use `--count` to replace grouped rule conditions:

List operators such as `in` and `not_in` split values on comma or pipe
separators and compare exact full values after trimming each token. Numeric
operators require a numeric request value; a nonnumeric request value fails the
rule requirement.

```bash
./dockistrate.sh add-security-rule example.com 2 \
  header X-App-Mode equals Preview \
  method - equals GET \
  --mode and --code 403
```

Update or remove rules when policy changes:

```bash
./dockistrate.sh list-security-rules
./dockistrate.sh update-security-rule 1 --code 404
./dockistrate.sh update-security-rule 1 --count 1 header User-Agent not_contains "BadBot"
./dockistrate.sh remove-security-rule 1
```

## Status Code Precedence

Security rules use per-rule `--code` first, then backend-specific security-rule
status, then the global security-rule status. ACL deny rules use their stored
row status when present, then backend-specific ACL status, then the global ACL
status.

## Verification

```bash
./dockistrate.sh list-acl
./dockistrate.sh list-security-rules
./dockistrate.sh update-nginx-config
./dockistrate.sh check-config
./dockistrate.sh add-acl example.com l7 allow 127.0.0.1/32
curl -i http://localhost -H 'Host: example.com'
```

Generated ACL and security-rule includes are part of the mocked regression suite.
