# shellcheck shell=bash
if ! declare -F __dockistrate_access_log_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/access_log.sh first.
  # shellcheck source=../access_log.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/access_log.sh"
fi

function list_log_fields() {
  _access_log_load_fields || return 1
  local n=1 tag line
  for line in "${ACCESS_LOG_FIELDS[@]}"; do
    tag=""
    if [[ "$line" =~ \$sent_http_ ]]; then
      tag="[response]"
    elif [[ "$line" =~ \$http_ ]]; then
      tag="[request]"
    fi
    printf '%d: %s %s\n' "$n" "$tag" "$line"
    n=$((n + 1))
  done
}
