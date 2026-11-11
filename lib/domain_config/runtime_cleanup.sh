# shellcheck shell=bash

function _domain_runtime_prepare_cleanup_proxy() {
  [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] && [ "${SKIP_DOCKER_CHECKS:-false}" != true ] || return 0
  _nginx_prepare_runtime_rollback "$NGINX_IMAGE" || return 1
  domain_config_runtime_capture_proxy || return 1
  # Cleanup removes bind-mounted directories. Restoring their paths creates
  # new inodes, so recovery must recreate the proxy with the restored mounts.
  _nginx_mark_runtime_rollback_needed
}

function domain_config_clean_owned_material() {
  local domain="$1" root="${DOMAINS_DIR:-${STATE_DIR}/domains}/$1" dir="" id="" status=0
  is_valid_domain "$domain" || return 1
  for dir in "$root/certs/"*; do
    [ -d "$dir" ] || continue
    runtime_state_path_guard_if_declared "$dir" "domain certificate cleanup" || return 1
    id="${dir##*/}"; _domain_cert_id_valid "$id" || return 1
    status=0
    _domain_cert_has_consumers "$domain/$id" || status=$?
    if [ "$status" -eq 0 ]; then
      printf '[Info] Retained certificate %s/%s used by another domain.\n' "$domain" "$id"
      continue
    fi
    [ "$status" -eq 1 ] || return 1
    _domain_cert_record_removal "$domain" "$id" || return 1
    safe_rm_rf "$dir" "$root/certs" || return 1
  done
  if [ -e "$root/mtls" ]; then
    runtime_state_path_guard_if_declared "$root/mtls" "domain authority cleanup" || return 1
    safe_rm_rf "$root/mtls" "$root" || return 1
  fi
}

function _domain_runtime_stage_proxy_delete() {
  local id=""
  # Explicit removal still performs its requested action when optional Docker
  # validation is skipped; ownership and immutable-ID checks remain required.
  nginx_container_is_managed || return 0
  id="$(docker inspect -f '{{.Id}}' "$NGINX_CONTAINER_NAME")" || return 1
  _backend_runtime_is_full_container_id "$id" || return 1
  _domain_runtime_record proxy_remove proxy.dockistrate.invalid old_id "$id" || return 1
  _domain_runtime_finish_operation
}

function _domain_runtime_delete_proxy() {
  local file="$1" id="" actual=""
  id="$(_domain_runtime_get "$file" old_id)" || return 1
  _backend_runtime_is_full_container_id "$id" || return 1
  _backend_runtime_container_is_absent "$id" && return 0
  # Ownership was verified before this immutable full ID was journaled. Never
  # resolve a name again after commit, when a different container could use it.
  actual="$(docker inspect -f '{{.Id}}' "$id")" || return 1
  [ "$actual" = "$id" ] || return 1
  remove_container_and_anonymous_volumes "$id" >/dev/null || return 1
  echo "[Info] Removed Nginx container."
  if declare -F log_msg >/dev/null 2>&1; then log_msg "Removed Nginx container."; fi
}

function _domain_runtime_cleanup_shared() {
  local scope="$1" path="" lock=""
  case "$scope" in backend | config | all) ;; *) return 1 ;; esac
  for path in "${STATE_DIR}/shared/acme" "${STATE_DIR}/shared/certificate_receipts"; do
    runtime_state_path_guard_if_declared "$path" "uninstalled issuer material" || return 1
    [ ! -d "$path" ] || safe_rm_rf "$path" "${STATE_DIR}/shared" || return 1
  done
  if [ "$scope" = all ] && [ -d "$TMP_DIR" ]; then
    lock="$(_transaction_lock_dir)" || return 1
    for path in "$TMP_DIR"/* "$TMP_DIR"/.[!.]* "$TMP_DIR"/..?*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      [ "$path" != "$lock" ] || continue
      if [ -d "$path" ] && [ ! -L "$path" ]; then safe_rm_rf "$path" "$TMP_DIR" || return 1
      else safe_rm_f "$path" "$TMP_DIR" || return 1; fi
    done
    DOMAIN_CONFIG_REMOVE_EMPTY_TMP=true
  fi
}

function domain_config_runtime_post_release_cleanup() {
  if [ "${DOMAIN_CONFIG_REMOVE_EMPTY_TMP:-false}" = true ]; then
    # A concurrent command may already own a new lock. Empty-only removal
    # preserves that command's directory and every file it has created.
    rmdir "$TMP_DIR" 2>/dev/null || true
    unset DOMAIN_CONFIG_REMOVE_EMPTY_TMP
  fi
}
