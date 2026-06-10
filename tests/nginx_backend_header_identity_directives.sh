#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/nginx.sh"

if declare -F _escape_nginx_value >/dev/null 2>&1; then
  echo "[Error] Expected _escape_nginx_value to remain unloaded in this isolated nginx test." >&2
  exit 1
fi

rendered="$(_backend_header_identity_directives 'primary.example.com' 'alias.example.com')" || {
  echo "[Error] Expected _backend_header_identity_directives to render without security_rules helpers." >&2
  exit 1
}

if [[ "$rendered" != *'set $dockistrate_backend_header_key "primary.example.com";'* ]]; then
  echo "[Error] Expected primary backend identity directive in output." >&2
  exit 1
fi

if [[ "$rendered" != *'if ($host = alias.example.com) { set $dockistrate_backend_header_key "alias.example.com"; }'* ]]; then
  echo "[Error] Expected alias backend identity directive in output." >&2
  exit 1
fi

echo "nginx backend header identity directive checks passed."
