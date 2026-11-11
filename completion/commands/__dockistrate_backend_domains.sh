#!/usr/bin/env bash

__dockistrate_backend_domains() {
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    awk -F',' '$1=="backend" {print $2}' "$BACKEND_PORTS_FILE" | sort -u
  fi
}

# ACL targets include ordinary aliases and dedicated hosts. These columns are
# domain names, so valid values cannot contain an embedded comma or quote.
__dockistrate_acl_domains() {
  {
    __dockistrate_backend_domains
    if [ -f "${BACKEND_ALIASES_FILE:-}" ]; then
      awk -F',' '
        function domain_field(value) {
          if (value ~ /^"[^"]*"$/) return substr(value, 2, length(value) - 2)
          if (value ~ /"/) return ""
          return value
        }
        NR > 1 && NF == 3 {
          sub(/\r$/, "", $3)
          kind = domain_field($1); name = domain_field($2); target = domain_field($3)
          if ((kind == "alias" || kind == "dedicated") && name != "" && target != "") print tolower(name)
        }
      ' "$BACKEND_ALIASES_FILE"
    fi
  } | LC_ALL=C sort -u
}

__dockistrate_server_domains() {
  {
    __dockistrate_backend_domains
    if [ -f "${BACKEND_ALIASES_FILE:-}" ]; then
      awk -F',' 'NR > 1 {gsub(/"/, "", $1); gsub(/"/, "", $2); if ($1 == "dedicated") print tolower($2)}' "$BACKEND_ALIASES_FILE"
    fi
  } | LC_ALL=C sort -u
}
