# shellcheck shell=bash

# Cache only a successful BSD syntax preference, never filesystem metadata.
# GNU remains the default without cache bookkeeping on its successful path.
# These declarations discard inherited environment values when sourced.
PERMISSIONS_STAT_CACHED_DIALECT=""
PERMISSIONS_STAT_CACHED_PATH=""
PERMISSIONS_STAT_CACHED_PWD=""

function _permissions_stat_read() {
  local gnu_format="${1:-}" bsd_format="${2:-}" record="" tried_bsd=false
  shift 2 || return 1
  PERMISSIONS_STAT_RECORD=""
  PERMISSIONS_STAT_DIALECT=""

  # Only a BSD preference needs validation. Function mocks always retain the
  # original GNU-then-BSD order, and leave the external tool's choice intact.
  if [ "${PERMISSIONS_STAT_CACHED_DIALECT:-}" = bsd ] &&
    [ "${PERMISSIONS_STAT_CACHED_PATH:-}" = "${PATH:-}" ] &&
    [ "${PERMISSIONS_STAT_CACHED_PWD:-}" = "${PWD:-}" ] &&
    ! declare -F stat >/dev/null 2>&1; then
    tried_bsd=true
    if record="$(stat -f "$bsd_format" "$@" 2>/dev/null || exit 1)"; then
      # Returned to permission readers in sibling modules.
      # shellcheck disable=SC2034
      PERMISSIONS_STAT_RECORD="$record"
      # shellcheck disable=SC2034
      PERMISSIONS_STAT_DIALECT=bsd
      return 0
    fi
    # The executable may have changed in place. Retry GNU once, never BSD twice.
    PERMISSIONS_STAT_CACHED_DIALECT=""
  fi

  # Guard expected probe failures inside substitutions: inherited Bash 3 ERR
  # traps must not roll back a handled portability fallback.
  if record="$(stat -c "$gnu_format" "$@" 2>/dev/null || exit 1)"; then
    # shellcheck disable=SC2034
    PERMISSIONS_STAT_RECORD="$record"
    # shellcheck disable=SC2034
    PERMISSIONS_STAT_DIALECT=gnu
    return 0
  fi
  [ "$tried_bsd" = false ] || return 1
  if record="$(stat -f "$bsd_format" "$@" 2>/dev/null || exit 1)"; then
    # shellcheck disable=SC2034
    PERMISSIONS_STAT_RECORD="$record"
    # shellcheck disable=SC2034
    PERMISSIONS_STAT_DIALECT=bsd
    if ! declare -F stat >/dev/null 2>&1; then
      PERMISSIONS_STAT_CACHED_DIALECT=bsd
      PERMISSIONS_STAT_CACHED_PATH="${PATH:-}"
      PERMISSIONS_STAT_CACHED_PWD="${PWD:-}"
    fi
    return 0
  fi
  if ! declare -F stat >/dev/null 2>&1; then PERMISSIONS_STAT_CACHED_DIALECT=""; fi
  return 1
}

function __dockistrate_permissions_stat_loaded() {
  :
}
