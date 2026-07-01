#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/security_rules/common.sh
source "$ROOT_DIR/lib/security_rules/common.sh"
# shellcheck source=../lib/security_rules/_sr_strings.sh
source "$ROOT_DIR/lib/security_rules/_sr_strings.sh"
# shellcheck source=../lib/security_rules/_sr_numeric.sh
source "$ROOT_DIR/lib/security_rules/_sr_numeric.sh"
# shellcheck source=../lib/security_rules/_sr_selectors.sh
source "$ROOT_DIR/lib/security_rules/_sr_selectors.sh"
# shellcheck source=../lib/security_rules/_sr_db.sh
source "$ROOT_DIR/lib/security_rules/_sr_db.sh"
# shellcheck source=../lib/security_rules/_sr_builders.sh
source "$ROOT_DIR/lib/security_rules/_sr_builders.sh"
# shellcheck source=../lib/security_rules/build_security_rules_inc.sh
source "$ROOT_DIR/lib/security_rules/build_security_rules_inc.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_sec_meta.XXXXXX")"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

CONFIG_DIR="$TMP_ROOT/config"
NGINX_HTTP_CONF_DIR="$CONFIG_DIR/nginx_conf/conf.d"
SECURITY_RULES_DB="$CONFIG_DIR/security_rules.csv"
SECURITY_RULES_INC="$NGINX_HTTP_CONF_DIR/security_rules.inc"
SECURITY_IP_RULES_DB="$CONFIG_DIR/security_ip_rules.csv"
mkdir -p "$NGINX_HTTP_CONF_DIR"

function build_security_ip_includes() { :; }
function get_backend_security_rule_status() { printf '%s\n' 403; }
function backend_for_dedicated_host() { :; }
function should_inherit_security_rules() { return 1; }

function write_security_rule_row() {
  local domain="${1:-example.com}" mode="${2:-single}" code="${3:-403}" count="${4:-1}" reason="${5:--}" loc="${6:-auto}" extra_condition="${7:-}"
  local enabled="${8:-1}"
  local slot=""

  {
    printf '%s\n' "$STATE_SECURITY_RULES_HEADER"
    printf '%s,%s,%s,%s,%s,header,X-Test,equals,yes' "$enabled" "$domain" "$mode" "$code" "$count"
    for slot in 2 3 4 5 6 7 8 9 10; do
      if [ "$slot" = "2" ] && [ "$extra_condition" = "extra" ]; then
        printf ',header,X-Extra,equals,no'
      else
        printf ',,,,'
      fi
    done
    printf ',%s,%s\n' "$reason" "$loc"
  } >"$SECURITY_RULES_DB"
}

function expect_build_security_rules_failure() {
  local expected="${1:-}" output=""
  if output="$(build_security_rules_inc 2>&1)"; then
    echo "[Error] Expected build_security_rules_inc to reject persisted security rule state." >&2
    exit 1
  fi
  case "$output" in
  *"$expected"*) ;;
  *)
    echo "$output" >&2
    echo "[Error] Expected build_security_rules_inc output to contain: ${expected}" >&2
    exit 1
    ;;
  esac
}

if is_valid_reason_value 'blocked $request_uri'; then
  echo "[Error] reason metadata validator accepted an Nginx variable reference." >&2
  exit 1
fi
if is_valid_loc_value 'rule:$host'; then
  echo "[Error] source_location metadata validator accepted an Nginx variable reference." >&2
  exit 1
fi
if ! _sr_validate_rule_triplet 'header:X-Test' 'matches' '^foo$' 'regex anchors should remain valid'; then
  echo "[Error] Regex condition value with dollar anchor should remain valid." >&2
  exit 1
fi
expr="$(_sr_exprs matches '^foo$')"
if ! grep -Fq '^foo$' <<<"$expr"; then
  echo "[Error] Regex expression lost literal dollar anchor." >&2
  exit 1
fi

write_security_rule_row example.com single 403 1 'blocked $request_uri' auto
expect_build_security_rules_failure "reason is invalid"

bad_domain='example.com; return 421; #'
write_security_rule_row "$bad_domain" single 403 1 '-' auto
expect_build_security_rules_failure "domain '${bad_domain}' is invalid"
if [ -f "$SECURITY_RULES_INC" ] && grep -Fq 'return 421' "$SECURITY_RULES_INC"; then
  echo "[Error] Invalid persisted security rule domain was rendered into security_rules.inc." >&2
  exit 1
fi

write_security_rule_row example.com single 403 1 '-' auto '' maybe
expect_build_security_rules_failure "enabled must be 0 or 1"

write_security_rule_row example.com and 403 1 '-' auto
expect_build_security_rules_failure "mode 'and' must be single when condition_count is 1"

write_security_rule_row example.com single 403 2 '-' auto
expect_build_security_rules_failure "mode 'single' must be 'and' or 'or' when condition_count is greater than 1"

write_security_rule_row example.com single '403; return 422; #' 1 '-' auto
expect_build_security_rules_failure "status_code '403; return 422; #' is invalid"

write_security_rule_row example.com single 403 0 '-' auto
expect_build_security_rules_failure "condition_count '0' must be 1..10"

write_security_rule_row example.com single 403 1 '-' auto extra
expect_build_security_rules_failure "condition 2 fields must be empty when condition_count is 1"

function get_backend_security_rule_status() { printf '%s\n' '403; return 423; #'; }
write_security_rule_row example.com single '-' 1 '-' auto
expect_build_security_rules_failure "effective status code '403; return 423; #' is invalid"

echo "[tests] security_rule_metadata_validation.sh: PASS"
