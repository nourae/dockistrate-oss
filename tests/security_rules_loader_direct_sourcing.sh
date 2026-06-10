#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  unset BASE_DIR STATE_DIR CONFIG_DIR NGINX_CONFIG_DIR NGINX_HTTP_CONF_DIR NGINX_STREAM_CONF_DIR
  unset SECURITY_RULES_FILE SECURITY_IP_RULES_FILE SECURITY_RULES_DB SECURITY_RULES_INC

  # shellcheck source=../lib/security_rules/common.sh
  source "$ROOT_DIR/lib/security_rules/common.sh"

  expected_config_dir="$ROOT_DIR/state/config"
  expected_http_conf_dir="$expected_config_dir/nginx_conf/conf.d"

  [ "$CONFIG_DIR" = "$expected_config_dir" ]
  [ "$NGINX_HTTP_CONF_DIR" = "$expected_http_conf_dir" ]
  [ "$SECURITY_RULES_DB" = "$expected_config_dir/security_rules.csv" ]
  [ "$SECURITY_IP_RULES_DB" = "$expected_config_dir/security_ip_rules.csv" ]
  [ "$SECURITY_RULES_INC" = "$expected_http_conf_dir/security_rules.inc" ]

  if ! declare -F __dockistrate_security_rules_common_loaded >/dev/null 2>&1; then
    echo "Expected direct sourcing common.sh to expose the security-rules common load sentinel." >&2
    exit 1
  fi

  trimmed="$(_sr_trim_whitespace "  keep-me  ")"
  if [ "$trimmed" != "keep-me" ]; then
    echo "Expected direct sourcing common.sh to keep helper behavior intact." >&2
    exit 1
  fi
'

ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  unset BASE_DIR STATE_DIR CONFIG_DIR NGINX_CONFIG_DIR NGINX_HTTP_CONF_DIR NGINX_STREAM_CONF_DIR
  unset SECURITY_RULES_FILE SECURITY_IP_RULES_FILE SECURITY_RULES_DB SECURITY_RULES_INC

  # shellcheck source=../lib/security_rules.sh
  source "$ROOT_DIR/lib/security_rules.sh"

  for name in __dockistrate_security_rules_loaded __dockistrate_security_rules_common_loaded add_security_rule list_security_rules build_security_rules_inc _sr_write_db_line; do
    if ! declare -F "$name" >/dev/null 2>&1; then
      echo "$name should be available after directly sourcing lib/security_rules.sh" >&2
      exit 1
    fi
  done

  bad_value="$(printf "bad\nvalue")"
  if _sr_validate_value "$bad_value" >/dev/null 2>&1; then
    echo "Expected direct sourcing lib/security_rules.sh to preserve strict security rule value validation." >&2
    exit 1
  fi
'

echo "Security rules loader direct sourcing checks passed."
