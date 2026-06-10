#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/nginx/common.sh"

TRUSTED_PROXY_RANGES="192.0.2.10 10.0.0.0/8"
REAL_IP_RECURSIVE="on"
valid_output="$(_real_ip_directives "X-Forwarded-For")"
if [[ "$valid_output" != *"set_real_ip_from 192.0.2.10;"* ]]; then
  echo "[Error] Expected real_ip directives to include a valid trusted proxy IP." >&2
  exit 1
fi
if [[ "$valid_output" != *"set_real_ip_from 10.0.0.0/8;"* ]]; then
  echo "[Error] Expected real_ip directives to include a valid trusted proxy CIDR." >&2
  exit 1
fi

TRUSTED_PROXY_RANGES="10.0.0.0/8; return 200;"
if invalid_output="$(_real_ip_directives "X-Forwarded-For" 2>&1)"; then
  echo "[Error] Expected _real_ip_directives to reject an invalid trusted proxy token." >&2
  exit 1
fi
if [[ "$invalid_output" != *"Invalid trusted proxy range in persisted global settings: 10.0.0.0/8;"* ]]; then
  echo "[Error] Expected invalid trusted proxy token output to name the rejected token." >&2
  exit 1
fi

echo "trusted proxy render validation checks passed."
