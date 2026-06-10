# shellcheck shell=bash

function _certbot_docker_is_darwin_host() {
  [ "$(uname -s 2>/dev/null || true)" = "Darwin" ]
}

function _certbot_docker_is_numeric_id() {
  case "${1:-}" in
  '' | *[!0-9]*)
    return 1
    ;;
  *)
    return 0
    ;;
  esac
}

function _certbot_docker_numeric_id_or_fallback() {
  local candidate="${1:-}"
  local fallback_flag="${2:-}"

  if ! _certbot_docker_is_numeric_id "$candidate"; then
    id "$fallback_flag"
    return
  fi

  printf '%s\n' "$candidate"
}

function _certbot_docker_path_stat() {
  local certbot_path="${1:-}"

  stat -f '%u %g %Lp' "$certbot_path" 2>/dev/null ||
    stat -c '%u %g %a' "$certbot_path" 2>/dev/null
}

function _certbot_docker_normalize_mode_digits() {
  local mode="${1:-}"

  case "$mode" in
  '' | *[!0-7]*)
    return 1
    ;;
  esac

  while [ "${#mode}" -gt 3 ]; do
    mode="${mode#?}"
  done
  while [ "${#mode}" -lt 3 ]; do
    mode="0${mode}"
  done

  printf '%s\n' "$mode"
}

function _certbot_docker_mode_digit_allows_directory_write() {
  case "${1:-}" in
  3 | 7)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

function _certbot_docker_mode_digit_allows_file_write() {
  case "${1:-}" in
  2 | 3 | 6 | 7)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

function _certbot_docker_mode_digit_allows_path_write() {
  local path_kind="${1:-}" mode_digit="${2:-}"

  case "$path_kind" in
  dir)
    _certbot_docker_mode_digit_allows_directory_write "$mode_digit"
    ;;
  file)
    _certbot_docker_mode_digit_allows_file_write "$mode_digit"
    ;;
  *)
    return 1
    ;;
  esac
}

function _certbot_docker_path_writable_by_user() {
  local certbot_uid="${1:-}" certbot_gid="${2:-}" certbot_path="${3:-}" path_kind="${4:-}"
  local stat_output="" owner_uid="" owner_gid="" mode=""
  local owner_perm="" group_perm="" other_perm=""

  case "$path_kind" in
  dir)
    [ -d "$certbot_path" ] || return 1
    ;;
  file)
    [ -f "$certbot_path" ] || return 1
    ;;
  *)
    return 1
    ;;
  esac

  stat_output="$(_certbot_docker_path_stat "$certbot_path")" || return 1
  set -- $stat_output
  owner_uid="${1:-}"
  owner_gid="${2:-}"
  mode="$(_certbot_docker_normalize_mode_digits "${3:-}")" || return 1

  _certbot_docker_is_numeric_id "$owner_uid" || return 1
  _certbot_docker_is_numeric_id "$owner_gid" || return 1

  owner_perm="${mode:0:1}"
  group_perm="${mode:1:1}"
  other_perm="${mode:2:1}"

  if [ "$certbot_uid" = "$owner_uid" ]; then
    _certbot_docker_mode_digit_allows_path_write "$path_kind" "$owner_perm"
    return
  fi
  if [ "$certbot_gid" = "$owner_gid" ]; then
    _certbot_docker_mode_digit_allows_path_write "$path_kind" "$group_perm"
    return
  fi
  _certbot_docker_mode_digit_allows_path_write "$path_kind" "$other_perm"
}

function _certbot_docker_mount_tree_writable_by_user() {
  local certbot_uid="${1:-}" certbot_gid="${2:-}" mount_root="${3:-}"
  local certbot_paths="" certbot_path="" path_kind=""

  [ -d "$mount_root" ] || return 1

  certbot_paths="$(find -H "$mount_root" \( -type d -o -type f \) -print 2>/dev/null)" || return 1
  while IFS= read -r certbot_path; do
    [ -n "$certbot_path" ] || continue
    if [ -d "$certbot_path" ]; then
      path_kind="dir"
    elif [ -f "$certbot_path" ]; then
      path_kind="file"
    else
      continue
    fi
    _certbot_docker_path_writable_by_user "$certbot_uid" "$certbot_gid" "$certbot_path" "$path_kind" || return 1
  done <<EOF_CERTBOT_PATHS
$certbot_paths
EOF_CERTBOT_PATHS
}

function _certbot_docker_mount_roots_writable_by_user() {
  local certbot_uid="${1:-}" certbot_gid="${2:-}" mount_root=""
  shift 2 || true

  for mount_root in "$@"; do
    [ -n "$mount_root" ] || continue
    _certbot_docker_mount_tree_writable_by_user "$certbot_uid" "$certbot_gid" "$mount_root" || return 1
  done
}

function _certbot_docker_prepare_mount_roots_for_user() {
  local certbot_uid="${1:-}" certbot_gid="${2:-}"
  shift 2 || true

  _certbot_docker_mount_roots_writable_by_user "$certbot_uid" "$certbot_gid" "$@"
}

function certbot_docker_host_user_mapping() {
  local certbot_uid="" certbot_gid=""

  _certbot_docker_is_darwin_host || return 1

  certbot_uid="$(_certbot_docker_numeric_id_or_fallback "${SUDO_UID:-}" "-u")" || return 2
  certbot_gid="$(_certbot_docker_numeric_id_or_fallback "${SUDO_GID:-}" "-g")" || return 2

  [ -n "$certbot_uid" ] || return 2
  [ -n "$certbot_gid" ] || return 2

  if ! _certbot_docker_prepare_mount_roots_for_user "$certbot_uid" "$certbot_gid" "$@"; then
    echo "[Error] Refusing to run Darwin Certbot without host-user mapping because mounted Certbot directories are not writable by ${certbot_uid}:${certbot_gid}." >&2
    echo "[Error] Run 'sudo ./dockistrate.sh fix-permissions --certbot-darwin-user' to prepare Darwin Certbot mounts for host-user mapping." >&2
    return 2
  fi

  printf '%s:%s\n' "$certbot_uid" "$certbot_gid"
}
