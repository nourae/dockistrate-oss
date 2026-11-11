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
$STATE_SECURITY_RULES_HEADER
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
