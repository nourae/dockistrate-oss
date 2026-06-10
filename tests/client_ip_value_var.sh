#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/nginx/common.sh"

xff_value="$(_client_ip_value_var "X-Forwarded-For")"
if [ "$xff_value" != '$proxy_add_x_forwarded_for' ]; then
  echo "[Error] Expected X-Forwarded-For to use \$proxy_add_x_forwarded_for, got: $xff_value" >&2
  exit 1
fi

mixed_case_xff_value="$(_client_ip_value_var "x-FoRwArDeD-FoR")"
if [ "$mixed_case_xff_value" != '$proxy_add_x_forwarded_for' ]; then
  echo "[Error] Expected mixed-case X-Forwarded-For to use \$proxy_add_x_forwarded_for, got: $mixed_case_xff_value" >&2
  exit 1
fi

real_ip_value="$(_client_ip_value_var "X-Real-IP")"
if [ "$real_ip_value" != '$remote_addr' ]; then
  echo "[Error] Expected X-Real-IP to use \$remote_addr, got: $real_ip_value" >&2
  exit 1
fi

cf_connecting_ip_value="$(_client_ip_value_var "CF-Connecting-IP")"
if [ "$cf_connecting_ip_value" != '$remote_addr' ]; then
  echo "[Error] Expected CF-Connecting-IP to use \$remote_addr, got: $cf_connecting_ip_value" >&2
  exit 1
fi

echo "client_ip_value_var checks passed."
