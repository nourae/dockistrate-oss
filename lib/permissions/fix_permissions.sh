# shellcheck shell=bash
if ! declare -F __dockistrate_permissions_common_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/permissions.sh first.
  # shellcheck source=./common.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

# Permission repair can run before runtime/archive setup. These files only
# declare functions; metadata mode does not initialize or copy runtime state.
# shellcheck source=./metadata_transaction.sh
source "${PERMISSIONS_COMMON_DIR}/metadata_transaction.sh"
# shellcheck source=../backups/begin_transaction.sh
source "${PERMISSIONS_COMMON_DIR}/../backups/begin_transaction.sh"
# shellcheck source=../backups/end_transaction_success.sh
source "${PERMISSIONS_COMMON_DIR}/../backups/end_transaction_success.sh"

function _fix_permissions_is_darwin_host() {
  [ "$(uname -s 2>/dev/null || true)" = "Darwin" ]
}

function _fix_permissions_is_numeric_id() {
  case "${1:-}" in
  '' | *[!0-9]*)
    return 1
    ;;
  *)
    return 0
    ;;
  esac
}

function _fix_permissions_reject_symlinked_certbot_path() {
  local certbot_path="${1:-}" path_label="${2:-path}"

  [ -n "$certbot_path" ] || return 1
  if [ -L "$certbot_path" ]; then
    echo "[Error] Refusing to prepare symlinked Darwin Certbot ${path_label}: '${certbot_path}'." >&2
    return 1
  fi
  # This command intentionally skips runtime bootstrap. Validate every existing
  # component before creating missing leaves, including directly sourced use
  # where STATE_DIR may be unset. Keep the normal runtime containment check too.
  _runtime_path_reject_symlink_prefix_components "$certbot_path" "Darwin Certbot ${path_label}" || return 1
  runtime_state_path_guard "$certbot_path" "Darwin Certbot ${path_label}"
}

function _fix_permissions_normalize_directory_argument() {
  local output_variable="$1" input_path="" normalized="" component=""
  _runtime_path_to_absolute_lexical_assign input_path "$2" || return 1
  while [ -n "$input_path" ]; do
    component="${input_path%%/*}"
    if [ "$input_path" = "$component" ]; then
      input_path=""
    else
      input_path="${input_path#*/}"
    fi
    [ -z "$component" ] || normalized="${normalized}/${component}"
  done
  [ -n "$normalized" ] || normalized=/
  printf -v "$output_variable" '%s' "$normalized"
}

function _fix_permissions_prepare_certbot_root() {
  local requested="${1:-}" output_variable="${2:-}" kind="" created_path=""
  local created_device="" created_inode="" created_uid="" created_gid="" created_mode=""
  local physical_root="" complete=false
  while IFS= read -r -d '' kind; do
    case "$kind" in
    root)
      [ -z "$physical_root" ] && IFS= read -r -d '' physical_root || return 1
      ;;
    created)
      IFS= read -r -d '' created_path && IFS= read -r -d '' created_device &&
        IFS= read -r -d '' created_inode && IFS= read -r -d '' created_uid &&
        IFS= read -r -d '' created_gid && IFS= read -r -d '' created_mode || return 1
      PERMISSIONS_PLAN_PATHS+=("$created_path")
      PERMISSIONS_PLAN_ORIGINAL_MODES+=("$created_mode")
      PERMISSIONS_PLAN_ORIGINAL_DEVICES+=("$created_device")
      PERMISSIONS_PLAN_ORIGINAL_INODES+=("$created_inode")
      PERMISSIONS_PLAN_ORIGINAL_UIDS+=("$created_uid")
      PERMISSIONS_PLAN_ORIGINAL_GIDS+=("$created_gid")
      PERMISSIONS_PLAN_MODES+=(750)
      PERMISSIONS_PLAN_UIDS+=("$certbot_uid")
      PERMISSIONS_PLAN_GIDS+=("$certbot_gid")
      ;;
    complete)
      [ -n "$physical_root" ] && [ "$complete" = false ] || return 1
      complete=true
      ;;
    *) return 1 ;;
    esac
  done < <(_permissions_metadata_helper_mkdir_plan "$requested")
  # Process substitution has no exit-status channel in Bash 3. The helper
  # emits this final record only after a complete descriptor walk succeeds.
  [ "$complete" = true ] || return 1
  printf -v "$output_variable" '%s' "$physical_root"
}

function _fix_permissions_plan_certbot_mount_tree() {
  local mount_root="${1:-}" certbot_uid="${2:-}" certbot_gid="${3:-}" mode_profile="${4:-plain}"
  local created_count="${5:-0}" covered_root="${6:-}"
  local path="" wanted="" sensitive_status=0 inventory="" index=0 duplicate=false

  [ -n "$mount_root" ] && [ -d "$mount_root" ] || return 1
  _fix_permissions_is_numeric_id "$created_count" &&
    [ "$created_count" -le "${#PERMISSIONS_PLAN_PATHS[@]}" ] || return 1
  # The TLS tree is planned first. A plain root inside it needs no second walk.
  if [ -n "$covered_root" ]; then
    case "$mount_root" in "$covered_root" | "$covered_root"/*) return 0 ;; esac
  fi
  inventory="$(mktemp "${TMPDIR:-/tmp}/dockistrate-certbot-permissions.XXXXXX")" || return 1
  if ! find "$mount_root" \( -type d -o -type f \) -print0 >"$inventory"; then
    rm -f "$inventory"
    echo "[Error] Unable to traverse Darwin Certbot mount '${mount_root}'." >&2
    return 1
  fi
  local -a paths=()
  while IFS= read -r -d '' path; do
    [ "$path" != "$inventory" ] || continue
    paths+=("$path")
  done <"$inventory"
  rm -f "$inventory" || return 1
  for path in "${paths[@]}"; do
    if [ -n "$covered_root" ]; then
      case "$path" in "$covered_root" | "$covered_root"/*) continue ;; esac
    fi
    # Only the fixed mkdir-plan rows can overlap this traversal. Scanning the
    # growing file plan here would make preparation quadratic in tree size.
    duplicate=false
    for ((index = 0; index < created_count; index++)); do
      if [ "${PERMISSIONS_PLAN_PATHS[$index]}" = "$path" ]; then
        duplicate=true
        break
      fi
    done
    [ "$duplicate" != true ] || continue
    if ! _permissions_metadata_stat "$path"; then
      echo '[Error] Refusing unsafe entry in Darwin Certbot permission repair.' >&2
      return 1
    fi
    wanted=640
    if [ "$PERMISSIONS_STAT_TYPE" = directory ]; then
      wanted=750
    elif [ "$mode_profile" = tls ]; then
      if _is_sensitive_tls_file "$path"; then
        wanted=600
      else
        sensitive_status=$?
        [ "$sensitive_status" -eq 1 ] || return "$sensitive_status"
      fi
    fi
    PERMISSIONS_PLAN_PATHS+=("$path")
    PERMISSIONS_PLAN_ORIGINAL_MODES+=("$PERMISSIONS_STAT_MODE")
    PERMISSIONS_PLAN_ORIGINAL_DEVICES+=("")
    PERMISSIONS_PLAN_ORIGINAL_INODES+=("")
    PERMISSIONS_PLAN_ORIGINAL_UIDS+=("")
    PERMISSIONS_PLAN_ORIGINAL_GIDS+=("")
    PERMISSIONS_PLAN_MODES+=("$wanted")
    PERMISSIONS_PLAN_UIDS+=("$certbot_uid")
    PERMISSIONS_PLAN_GIDS+=("$certbot_gid")
  done
}

function fix_permissions_certbot_darwin_user() {
  (
    local TRANSACTION_DEPTH=0 PERMISSIONS_TRANSACTION_ACTIVE=false
    trap - ERR EXIT
    local current_uid="" certbot_uid="${SUDO_UID:-}" certbot_gid="${SUDO_GID:-}"
    local certificate_root="" letsencrypt_root="" acme_root="" transaction_root="" planned_path="" created_count=0
    local -a PERMISSIONS_PLAN_PATHS=() PERMISSIONS_PLAN_MODES=() PERMISSIONS_PLAN_UIDS=()
    local -a PERMISSIONS_PLAN_GIDS=() PERMISSIONS_PLAN_ORIGINAL_MODES=()
    local -a PERMISSIONS_PLAN_ORIGINAL_DEVICES=() PERMISSIONS_PLAN_ORIGINAL_INODES=()
    local -a PERMISSIONS_PLAN_ORIGINAL_UIDS=() PERMISSIONS_PLAN_ORIGINAL_GIDS=()

    if ! _fix_permissions_is_darwin_host; then
      echo "[Error] fix-permissions --certbot-darwin-user is only supported on macOS/Darwin." >&2
      return 1
    fi

    current_uid="$(id -u 2>/dev/null || true)"
    if [ "$current_uid" != "0" ]; then
      echo "[Error] fix-permissions --certbot-darwin-user must be run with sudo." >&2
      return 1
    fi
    if ! _fix_permissions_is_numeric_id "$certbot_uid" || ! _fix_permissions_is_numeric_id "$certbot_gid"; then
      echo "[Error] fix-permissions --certbot-darwin-user requires numeric SUDO_UID and SUDO_GID." >&2
      return 1
    fi
    if [ -z "${CERTS_DIR:-}" ] || [ -z "${ACME_WEBROOT_DIR:-}" ]; then
      echo "[Error] Certificate and ACME webroot directories are not configured." >&2
      return 1
    fi

    # Separator normalization preserves the existing mkdir -p spelling rules
    # without resolving any symlink or accepting dot/dot-dot components.
    _fix_permissions_normalize_directory_argument certificate_root "$CERTS_DIR" || return 1
    _fix_permissions_normalize_directory_argument acme_root "$ACME_WEBROOT_DIR" || return 1
    letsencrypt_root="${certificate_root%/}/letsencrypt"
    if declare -F domain_config_certificate_layout >/dev/null 2>&1 && domain_config_certificate_layout; then
      _fix_permissions_normalize_directory_argument letsencrypt_root "$(_domain_cert_acme_root)" || return 1
      certificate_root="${letsencrypt_root%/*}"
    fi

    _fix_permissions_reject_symlinked_certbot_path "$certificate_root" "certificate root" || return 1
    _fix_permissions_reject_symlinked_certbot_path "$letsencrypt_root" "Let's Encrypt mount root" || return 1
    _fix_permissions_reject_symlinked_certbot_path "$acme_root" "ACME webroot" || return 1
    _permissions_metadata_require_helper || return 1

    # mkdir and every later metadata mutation walk pinned directory descriptors.
    # A replaced parent cannot redirect creation through an unchecked symlink.
    _fix_permissions_prepare_certbot_root "$letsencrypt_root" letsencrypt_root || return 1
    _fix_permissions_prepare_certbot_root "$acme_root" acme_root || return 1
    created_count="${#PERMISSIONS_PLAN_PATHS[@]}"
    _fix_permissions_plan_certbot_mount_tree "$letsencrypt_root" "$certbot_uid" "$certbot_gid" tls "$created_count" || return 1
    _fix_permissions_plan_certbot_mount_tree "$acme_root" "$certbot_uid" "$certbot_gid" plain "$created_count" "$letsencrypt_root" || return 1
    transaction_root="${PERMISSIONS_PLAN_PATHS[0]}"
    for planned_path in "${PERMISSIONS_PLAN_PATHS[@]}"; do
      while :; do
        case "$planned_path" in "$transaction_root" | "${transaction_root%/}/"*) break ;; esac
        transaction_root="${transaction_root%/*}"
        [ -n "$transaction_root" ] || transaction_root=/
      done
    done
    # Plan the two selected trees and their newly created parents only. Existing
    # ancestors remain untouched. / may anchor the walk but is never planned.
    if [ "$transaction_root" = / ]; then
      begin_transaction --permissions "$transaction_root" --allow-filesystem-anchor || return 1
    else
      begin_transaction --permissions "$transaction_root" || return 1
    fi
    if ! _permissions_transaction_apply; then
      _permissions_transaction_rollback || true
      return 1
    fi
    if declare -F _certbot_docker_mount_roots_writable_by_user >/dev/null 2>&1; then
      if ! _certbot_docker_mount_roots_writable_by_user "$certbot_uid" "$certbot_gid" "$letsencrypt_root" "$acme_root"; then
        echo "[Error] Darwin Certbot mounts are still not writable by ${certbot_uid}:${certbot_gid}." >&2
        _permissions_transaction_rollback || true
        return 1
      fi
    fi
    end_transaction_success --permissions || return 1
    echo "[Info] Prepared Darwin Certbot mounts for ${certbot_uid}:${certbot_gid}: ${letsencrypt_root}, ${acme_root}"
  )
}

function _fix_permissions_is_private_subtree() {
  local path="${1:-}" root=""
  # fix_permissions resolves these dynamically scoped roots once before walking.
  for root in "${private_subtree_roots[@]-}"; do
    [ -n "$root" ] || continue
    case "$path" in "$root" | "$root"/*) return 0 ;; esac
  done
  return 1
}

function _fix_permissions_resolve_scoped_path() {
  local candidate="${1:-}" allow_ancestor="${2:-false}" parent="" resolved=""
  [ -n "$candidate" ] || return 1
  case "$candidate" in /*) ;; *) candidate="${PWD}/${candidate}" ;; esac
  candidate="${candidate%/}"
  # Check declared paths before resolving symlinks, including missing leaves.
  case "$candidate" in "$dir" | "$dir"/*)
    runtime_state_path_guard_if_declared "$candidate" "permission repair path" || return 2
    ;;
  esac
  [ -e "$candidate" ] || [ -L "$candidate" ] || return 1
  if [ -d "$candidate" ]; then
    _permissions_metadata_resolve_directory "$candidate" || return 2
    resolved="$PERMISSIONS_PHYSICAL_DIRECTORY"
  elif [ -L "$candidate" ]; then
    resolved="$(_runtime_path_realpath_portable "$candidate" && printf '.')" || return 2
    resolved="${resolved%.}"
  else
    _permissions_metadata_resolve_directory "${candidate%/*}" || return 2
    parent="$PERMISSIONS_PHYSICAL_DIRECTORY"
    resolved="${parent%/}/${candidate##*/}"
  fi
  case "$resolved" in
  "$dir" | "$dir"/*) ;;
  *)
    [ "$allow_ancestor" = true ] || return 1
    case "$dir" in "$resolved"/*) ;; *) return 1 ;; esac
    ;;
  esac
  runtime_state_path_guard_if_declared "$candidate" "permission repair path" || return 2
  [ ! -L "$resolved" ] || {
    echo "[Error] Refusing symlinked runtime permission repair path: $candidate" >&2
    return 2
  }
  SCOPED_PERMISSION_PATH="$resolved"
}

function _fix_permissions_collect_roots() {
  local candidate="" status=0
  for candidate in "${BACKUP_DIR:-}" "${TMP_DIR:-}" "${CAPTURE_DIR:-}"; do
    if _fix_permissions_resolve_scoped_path "$candidate" true; then
      private_subtree_roots+=("$SCOPED_PERMISSION_PATH")
    else
      status=$?
      [ "$status" -eq 1 ] || return 1
    fi
  done
  if [ -n "${STATE_DIR:-}" ]; then
    for candidate in "${STATE_DIR%/}/shared/acme" "${STATE_DIR%/}/shared/certificate_receipts" "${STATE_DIR%/}/runtime/transactions"; do
      if _fix_permissions_resolve_scoped_path "$candidate" true; then
        private_subtree_roots+=("$SCOPED_PERMISSION_PATH")
      else
        status=$?; [ "$status" -eq 1 ] || return 1
      fi
    done
    local domain_dir="" domain_root="${STATE_DIR%/}/domains"
    for candidate in "$domain_root" "$domain_root/"*/config "$domain_root/"*/certs "$domain_root/"*/mtls; do
      if _fix_permissions_resolve_scoped_path "$candidate" true; then
        restricted_subtree_roots+=("$SCOPED_PERMISSION_PATH")
        restricted_subtree_modes+=(750)
      else
        status=$?; [ "$status" -eq 1 ] || return 1
      fi
    done
    for candidate in "$domain_root/"*/runtime; do
      if _fix_permissions_resolve_scoped_path "$candidate" true; then
        private_subtree_roots+=("$SCOPED_PERMISSION_PATH")
      else
        status=$?; [ "$status" -eq 1 ] || return 1
      fi
    done
  fi
  for candidate in "${STATE_DIR:-}" "${CONFIG_DIR:-}" "${LOG_DIR:-}"     "${ERROR_LOG_DIR:-}" "${ACME_WEBROOT_DIR:-}"; do
    if _fix_permissions_resolve_scoped_path "$candidate"; then
      runtime_boundary_dirs+=("$SCOPED_PERMISSION_PATH")
    else
      status=$?
      [ "$status" -eq 1 ] || return 1
    fi
  done
  if _fix_permissions_resolve_scoped_path "${CERTS_DIR:-}" true; then
    restricted_subtree_roots+=("$SCOPED_PERMISSION_PATH")
    restricted_subtree_modes+=(750)
  else
    status=$?
    [ "$status" -eq 1 ] || return 1
  fi
  local nginx_mode=""
  for candidate in "${NGINX_CONFIG_DIR:-}" "${NGINX_HTTP_CONF_DIR:-}" "${NGINX_STREAM_CONF_DIR:-}"; do
    if _fix_permissions_resolve_scoped_path "$candidate" true; then
      if [ -z "$nginx_mode" ]; then
        # A scoped repair skips runtime bootstrap. Read existing image settings
        # only when repairing an Nginx tree, without creating or rewriting state.
        if declare -F load_config >/dev/null 2>&1 && [ -s "${GLOBAL_SETTINGS_FILE:-}" ]; then
          load_config || return 1
        fi
        nginx_mode="$(_runtime_nginx_config_dir_mode)"
      fi
      restricted_subtree_roots+=("$SCOPED_PERMISSION_PATH")
      restricted_subtree_modes+=("$nginx_mode")
    else
      status=$?
      [ "$status" -eq 1 ] || return 1
    fi
  done
  local -a PRIVATE_RUNTIME_FILE_PATHS=()
  _collect_private_runtime_file_paths
  for candidate in "${PRIVATE_RUNTIME_FILE_PATHS[@]}"     "${GLOBAL_SETTINGS_FILE:-}" "${CONFIG_DIR:-}/state_schema_version"; do
    if _fix_permissions_resolve_scoped_path "$candidate"; then
      _private_file_is_regular_and_unlinked "$SCOPED_PERMISSION_PATH" || {
        echo '[Error] Refusing unsafe runtime file in permission repair target.' >&2
        return 1
      }
    else
      status=$?
      [ "$status" -eq 1 ] || return 1
    fi
  done
}

function _fix_permissions_is_critical_script() {
  local path="$1" script="" base="${repair_base:-}"
  [ -n "$base" ] || return 1
  for script in dockistrate.sh tests/run.sh scripts/update-function-reference-appendices.sh     scripts/render-function-reference-html.sh tests/clean_all_regression.sh     tests/remove_backend_escaping.sh tests/docker_opts_parsing.sh tests/certs_timestamp.sh     tests/integration/test_cli.sh tests/integration/test_feature_configs.sh tests/mocks/docker; do
    [ "$path" != "$base/$script" ] || return 0
  done
  return 1
}

function _fix_permissions_plan_entry() {
  local path="$1" mode="" wanted="" ceiling=644 root="" status=0 index=0
  if ! _permissions_metadata_stat "$path"; then
    echo "[Error] Refusing unsafe or unreadable permission repair entry: $path" >&2
    return 1
  fi
  mode="$PERMISSIONS_STAT_MODE"
  if [ "$PERMISSIONS_STAT_TYPE" = directory ]; then
    printf -v wanted '%o' "$((8#$mode & 8#755))"
    for root in "${runtime_boundary_dirs[@]-}"; do
      [ "$path" != "$root" ] || wanted=750
    done
    for ((index = 0; index < ${#restricted_subtree_roots[@]}; index++)); do
      root="${restricted_subtree_roots[$index]}"
      case "$path" in "$root" | "$root"/*) wanted="${restricted_subtree_modes[$index]}" ;; esac
    done
    _fix_permissions_is_private_subtree "$path" && wanted=700
  else
    if _fix_permissions_is_private_subtree "$path" || _is_private_runtime_file "$path"; then
      ceiling=600
    elif _is_sensitive_tls_file "$path"; then
      ceiling=600
    else
      status=$?
      [ "$status" -eq 1 ] || return 1
      if _fix_permissions_is_critical_script "$path"; then
        wanted=755
      elif [ "$path" -ef "${GLOBAL_SETTINGS_FILE:-}" ] ||
        [ "$path" -ef "${CONFIG_DIR:-}/state_schema_version" ]; then
        ceiling=640
      elif [ "$((8#$mode & 8#111))" -ne 0 ]; then
        ceiling=755
      fi
    fi
    if [ -z "$wanted" ]; then
      printf -v wanted '%o' "$((8#$mode & 8#$ceiling))"
    fi
  fi
  PERMISSIONS_PLAN_PATHS+=("$path")
  PERMISSIONS_PLAN_ORIGINAL_MODES+=("$mode")
  PERMISSIONS_PLAN_MODES+=("$wanted")
  PERMISSIONS_PLAN_UIDS+=("$repair_uid")
  PERMISSIONS_PLAN_GIDS+=("$repair_gid")
}

function fix_permissions() {
  (
    # A subshell confines metadata transaction traps to this repair operation.
    # Restore can call us inside its archive transaction. Isolate that inherited
    # context here; the parent retains its lock, traps, and content rollback.
    local TRANSACTION_DEPTH=0
    local PERMISSIONS_TRANSACTION_ACTIVE=false
    trap - ERR EXIT
    local dir="${1:-${BASE_DIR:-}}" inventory="" path=""
    local repair_uid="" repair_gid="" repair_base="" SCOPED_PERMISSION_PATH=""
    local -a private_subtree_roots=() runtime_boundary_dirs=() restricted_subtree_roots=() restricted_subtree_modes=()
    local -a PERMISSIONS_PLAN_PATHS=() PERMISSIONS_PLAN_MODES=() PERMISSIONS_PLAN_UIDS=()
    local -a PERMISSIONS_PLAN_GIDS=() PERMISSIONS_PLAN_ORIGINAL_MODES=() entries=()
    local -a PERMISSIONS_PLAN_ORIGINAL_DEVICES=() PERMISSIONS_PLAN_ORIGINAL_INODES=()
    local -a PERMISSIONS_PLAN_ORIGINAL_UIDS=() PERMISSIONS_PLAN_ORIGINAL_GIDS=()
    [ -d "$dir" ] || {
      echo "[Error] Directory not found: $dir" >&2
      return 1
    }
    _permissions_metadata_resolve_directory "$dir" || return 1
    dir="$PERMISSIONS_PHYSICAL_DIRECTORY"
    [ "$dir" != / ] || {
      echo '[Error] Select a directory below the filesystem root for permission repair.' >&2
      return 1
    }
    if [ -d "${BASE_DIR:-}" ]; then
      _permissions_metadata_resolve_directory "$BASE_DIR" || return 1
      repair_base="$PERMISSIONS_PHYSICAL_DIRECTORY"
    fi
    _fix_permissions_collect_roots || return 1
    if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
      repair_uid="$(id -u "$SUDO_USER")" && repair_gid="$(id -g "$SUDO_USER")" || return 1
    else
      repair_uid="$(id -u)" && repair_gid="$(id -g)" || return 1
    fi

    _permissions_metadata_require_helper || return 1

    # Check traversal before starting metadata changes. NUL-delimited inventory
    # supports all filenames and never follows Certbot or external symlinks.
    inventory="$(mktemp "${TMPDIR:-/tmp}/dockistrate-permissions.XXXXXX")" || return 1
    _permissions_metadata_resolve_directory "${inventory%/*}" || { rm -f "$inventory"; return 1; }
    inventory="${PERMISSIONS_PHYSICAL_DIRECTORY%/}/${inventory##*/}"
    if ! find "$dir" \( -type d -o -type f \) -print0 >"$inventory"; then
      rm -f "$inventory"
      echo '[Error] Unable to traverse permission repair target.' >&2
      return 1
    fi
    while IFS= read -r -d '' path; do
      [ "$path" != "$inventory" ] || continue
      entries+=("$path")
    done <"$inventory"
    rm -f "$inventory" || return 1
    for path in "${entries[@]}"; do
      _fix_permissions_plan_entry "$path" || return 1
    done
    begin_transaction --permissions "$dir" || return 1
    if ! _permissions_transaction_apply; then
      _permissions_transaction_rollback || true
      return 1
    fi
    end_transaction_success --permissions || return 1
    echo "[Info] Permissions normalization complete under: $dir"
  )
}

function _nginx_image_runs_as_root() {
  local user=""
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi

  if [ -n "${NGINX_CONTAINER_NAME:-}" ] &&
    declare -F nginx_container_is_managed >/dev/null 2>&1 && nginx_container_is_managed; then
    user="$(docker inspect -f '{{.Config.User}}' "$NGINX_CONTAINER_NAME" 2>/dev/null || true)"
  elif [ -n "${NGINX_IMAGE:-}" ] && docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1; then
    user="$(docker image inspect "$NGINX_IMAGE" --format '{{.Config.User}}' 2>/dev/null || true)"
  fi

  case "$user" in
  "" | "0" | "0:0" | "root" | "root:root")
    return 0
    ;;
  esac

  return 1
}


# Dedicated load sentinel for entrypoints that source this helper directly.
function __dockistrate_fix_permissions_loaded() {
  :
}
