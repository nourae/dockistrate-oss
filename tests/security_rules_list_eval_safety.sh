#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules/_sr_strings.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules/_sr_db.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules/list_security_rules.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_sr_list_eval.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

SECURITY_RULES_DB="${TMP_ROOT}/security_rules.csv"
marker="${TMP_ROOT}/marker_should_not_exist"
payload="\$(touch ${marker})"

line="$(_sr_write_db_line 1 "example.com" "single" "403" "1" "header" "X-Test" "equals" "$payload")"
cat >"$SECURITY_RULES_DB" <<EOF_RULES
enabled,domain,mode,status_code,condition_count,selector_1,name_1,condition_1,value_1,selector_2,name_2,condition_2,value_2,selector_3,name_3,condition_3,value_3,selector_4,name_4,condition_4,value_4,selector_5,name_5,condition_5,value_5,selector_6,name_6,condition_6,value_6,selector_7,name_7,condition_7,value_7,selector_8,name_8,condition_8,value_8,selector_9,name_9,condition_9,value_9,selector_10,name_10,condition_10,value_10,reason,source_location
$line
EOF_RULES

output="$(list_security_rules)"

if [ -e "$marker" ]; then
  echo "[Error] list_security_rules executed payload while rendering rule values." >&2
  exit 1
fi

if ! grep -Fq "$payload" <<<"$output"; then
  echo "[Error] list_security_rules output did not preserve literal payload text." >&2
  exit 1
fi

echo "Security rule listing eval-safety checks passed."
