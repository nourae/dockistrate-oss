# shellcheck shell=bash

# Convert command name to a display friendly alias
COMMAND_ALIAS_PREFIX="CMD_ALIAS__"

function command_alias() {
  local _cmd="$1"
  local _cache_var="${COMMAND_ALIAS_PREFIX}${_cmd//[^A-Za-z0-9_]/_}"
  local _cached="${!_cache_var-}"
  if [ -n "$_cached" ]; then
    echo "$_cached"
    return 0
  fi

  local _alias="${_cmd//-/ }"
  _alias=$(echo "$_alias" | awk '{for(i=1;i<=NF;i++){ $i=toupper(substr($i,1,1))tolower(substr($i,2)) }}1')
  _alias=$(sed -E 's/Mtls/mTLS/g; s/Acl/ACL/g; s/L3/L3/g; s/Tls/TLS/g; s/Ip/IP/g; s/Ws/WS/g; s/Http/HTTP/g; s/Tcp/TCP/g; s/Hsts/HSTS/g; s/Csp/CSP/g; s/Id/ID/g' <<<"$_alias")
  printf -v "$_cache_var" '%s' "$_alias"
  echo "$_alias"
}
