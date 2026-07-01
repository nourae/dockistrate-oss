# shellcheck shell=bash

function set_visibility_policy() {
  local policy="${1:-}"
  if [ "$#" -ne 1 ]; then
    echo "${GLOBAL_SETTINGS_USAGE_PREFIX} set-visibility-policy <full|redacted>" >&2
    return 1
  fi
  if ! is_valid_visibility_policy "$policy"; then
    echo "${GLOBAL_SETTINGS_ERROR_PREFIX} Invalid visibility policy: ${policy}. Use full or redacted." >&2
    return 1
  fi

  VISIBILITY_POLICY="$policy"
  save_config || return 1
  echo "${GLOBAL_SETTINGS_INFO_PREFIX} VISIBILITY_POLICY set to $VISIBILITY_POLICY and saved in $GLOBAL_SETTINGS_FILE."
}
