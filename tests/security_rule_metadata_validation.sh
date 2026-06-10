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

{
  printf '%s\n' "$STATE_SECURITY_RULES_HEADER"
  printf '1,example.com,single,403,1,header,X-Test,equals,yes'
  for _ in 2 3 4 5 6 7 8 9 10; do
    printf ',,,,'
  done
  printf ',blocked $request_uri,auto\n'
} >"$SECURITY_RULES_DB"

if build_security_rules_inc >/dev/null 2>&1; then
  echo "[Error] Persisted security rule metadata with Nginx variable reference rendered successfully." >&2
  exit 1
fi

echo "[tests] security_rule_metadata_validation.sh: PASS"
