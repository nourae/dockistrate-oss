#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT_DIR="$ROOT_DIR/lib/security_rules"

entrypoint_names=()
while IFS= read -r entrypoint_path; do
  file_name="${entrypoint_path##*/}"
  entrypoint_names+=("${file_name%.sh}")
done < <(
  find "$ENTRYPOINT_DIR" -maxdepth 1 -type f -name '*.sh' ! -name 'common.sh' ! -name '_*.sh' -print |
    LC_ALL=C sort
)

for entrypoint_name in "${entrypoint_names[@]}"; do
  ROOT_DIR="$ROOT_DIR" ENTRYPOINT_NAME="$entrypoint_name" bash -c '
    set -Eeuo pipefail
    entrypoint_file="$ROOT_DIR/lib/security_rules/${ENTRYPOINT_NAME}.sh"

    # shellcheck source=/dev/null
    source "$entrypoint_file"

    for name in "$ENTRYPOINT_NAME" __dockistrate_security_rules_loaded __dockistrate_security_rules_common_loaded _sr_write_db_line; do
      if ! declare -F "$name" >/dev/null 2>&1; then
        echo "$name should be available after directly sourcing ${ENTRYPOINT_NAME}.sh" >&2
        exit 1
      fi
    done
  '
done

ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  # shellcheck source=../lib/security_rules/list_security_rules.sh
  source "$ROOT_DIR/lib/security_rules/list_security_rules.sh"

  bad_value="$(printf "bad\nvalue")"
  if _sr_validate_value "$bad_value" >/dev/null 2>&1; then
    echo "Expected direct sourcing list_security_rules.sh to preserve strict security rule value validation." >&2
    exit 1
  fi
'

echo "Security rules entrypoint direct sourcing checks passed."
