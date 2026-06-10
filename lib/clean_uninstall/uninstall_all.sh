# shellcheck shell=bash

function uninstall_all() {
  local arg
  local uninstall_scope="backend"

  while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
    --scope)
      if [ $# -lt 2 ]; then
        echo "[Error] --scope requires one of: backend, config, all." >&2
        return 1
      fi
      uninstall_scope="$2"
      uninstall_scope="$(printf '%s' "$uninstall_scope" | tr '[:upper:]' '[:lower:]')"
      shift
      ;;
    --scope=*)
      uninstall_scope="${arg#--scope=}"
      uninstall_scope="$(printf '%s' "$uninstall_scope" | tr '[:upper:]' '[:lower:]')"
      ;;
    *)
      echo "[Error] Unknown argument '$arg'. Supported flags: --scope <backend|config|all>." >&2
      return 1
      ;;
    esac
    shift
  done

  case "$uninstall_scope" in
  backend | config | all) ;;
  *)
    echo "[Error] Invalid scope '$uninstall_scope'. Use one of: backend, config, all." >&2
    return 1
    ;;
  esac

  if nginx_container_conflict_exists; then
    _nginx_conflict_error "uninstall-all"
    return 1
  fi

  local scope_summary
  case "$uninstall_scope" in
  backend)
    scope_summary="Nginx container, backend containers, backend state, generated Nginx config, and certs"
    ;;
  config)
    scope_summary="Nginx container, backend containers, full config, and certs"
    ;;
  all)
    scope_summary="Nginx container, backend containers, full config, certs, and runtime tmp/capture/acme data"
    ;;
  esac

  if ! confirm_prompt "Scope '${uninstall_scope}' removes ${scope_summary}. Logs and backups are retained. Type YES to proceed: " "strict_yes"; then
    echo "[Info] Aborting."
    return 1
  fi

  local started_txn=false
  if ! transaction_is_active; then
    if ! begin_transaction "uninstall_all_${uninstall_scope}" "$CONFIG_DIR" "$CERTS_DIR" "$TMP_DIR" "$CAPTURE_DIR" "$ACME_WEBROOT_DIR"; then
      return 1
    fi
    started_txn=true
  fi

  local backend_container_candidates="" dom cn
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    local bp_line="" bp_line_no=0
    while IFS= read -r bp_line || [ -n "$bp_line" ]; do
      bp_line_no=$((bp_line_no + 1))
      [ "$bp_line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$bp_line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
      [ "${STATE_BP_RECORD_TYPE:-}" = "backend" ] || continue
      dom="${STATE_BP_DOMAIN:-}"
      [ -n "$dom" ] || continue
      backend_container_candidates+=$'backend-'"$(sanitize_domain_name "$dom")"$'\n'
    done <"$BACKEND_PORTS_FILE"
  fi

  local dedicated_inheritance_file
  if declare -F dedicated_host_inheritance_file >/dev/null 2>&1; then
    dedicated_inheritance_file="$(dedicated_host_inheritance_file)"
  else
    dedicated_inheritance_file="${CONFIG_DIR}/dedicated_host_inheritance.csv"
  fi

  local -a backend_scope_files=(
    "$BACKEND_PORTS_FILE"
    "$BACKEND_ALIASES_FILE"
    "$dedicated_inheritance_file"
    "$BACKEND_HEADERS_FILE"
    "$BACKEND_HTTP_FILE"
    "$BACKEND_MTLS_FILE"
    "$BACKEND_CLIENT_IP_HEADER_FILE"
    "$BACKEND_PROXY_IP_HEADER_FILE"
    "$BACKEND_DOCKER_OPTS_FILE"
    "$BACKEND_ACL_POLICY_FILE"
    "$BACKEND_ACL_STATUS_FILE"
    "$BACKEND_SECURITY_RULE_STATUS_FILE"
    "$SECURITY_RULES_DB"
    "$SECURITY_IP_RULES_DB"
    "$PORT_TLS_PROTOCOLS_FILE"
    "$PORT_TLS_CIPHERS_FILE"
    "$NGINX_DIRECTIVES_FILE"
  )
  local -a backend_scope_dirs=(
    "$NGINX_CONFIG_DIR"
    "$PATH_HEADER_DIR"
    "$SECURITY_IP_DIR"
    "$SECURITY_IP_STREAM_DIR"
  )

  local artifact_file artifact_dir runtime_dir
  local deferred_tmp_cleanup=false
  case "$uninstall_scope" in
  backend)
    for artifact_file in "${backend_scope_files[@]}"; do
      if [ -f "$artifact_file" ]; then
        safe_rm_f "$artifact_file" "$CONFIG_DIR"
        echo "[Info] Removed $artifact_file."
      fi
    done

    for artifact_dir in "${backend_scope_dirs[@]}"; do
      if [ -d "$artifact_dir" ]; then
        safe_rm_rf "$artifact_dir" "$CONFIG_DIR"
        echo "[Info] Removed directory $artifact_dir."
      fi
    done
    ;;
  config | all)
    if [ -d "$CONFIG_DIR" ]; then
      safe_rm_rf "$CONFIG_DIR" "$STATE_DIR"
      echo "[Info] Removed directory $CONFIG_DIR."
    fi
    ;;
  esac

  if [ -d "$CERTS_DIR" ]; then
    safe_rm_rf "$CERTS_DIR" "$STATE_DIR"
    echo "[Info] Removed $CERTS_DIR."
  fi

  if [ "$uninstall_scope" = "all" ]; then
    for runtime_dir in "$TMP_DIR" "$CAPTURE_DIR" "$ACME_WEBROOT_DIR"; do
      if [ "$runtime_dir" = "$TMP_DIR" ]; then
        if [ "$started_txn" = true ]; then
          deferred_tmp_cleanup=true
        fi
        continue
      fi
      if [ -d "$runtime_dir" ]; then
        safe_rm_rf "$runtime_dir" "$STATE_DIR"
        echo "[Info] Removed directory $runtime_dir."
      fi
    done
  fi

  case "$uninstall_scope" in
  backend)
    echo "[Info] Backend uninstall complete. Global settings, logs, and backups were retained."
    ;;
  config)
    echo "[Info] Config uninstall complete. Logs and backups were retained."
    ;;
  all)
    echo "[Info] Full runtime uninstall complete. Logs and backups were retained."
    ;;
  esac

  log_msg "Ran uninstall-all (scope=${uninstall_scope})"
  case "$uninstall_scope" in
  backend) create_backup "" "UninstallAll_backend" ;;
  config) create_backup "" "UninstallAll_config" ;;
  all) create_backup "" "UninstallAll_all" ;;
  esac

  if [ "$started_txn" = true ]; then
    if nginx_container_is_managed; then
      if ! _cleanup_runtime_stage_container_delete "$NGINX_CONTAINER_NAME"; then
        echo "[Error] Failed to stage deletion for Nginx container '${NGINX_CONTAINER_NAME}'." >&2
        return 1
      fi
    fi
    if [ -n "$backend_container_candidates" ]; then
      while read -r cn; do
        [ -n "$cn" ] || continue
        if ! _cleanup_runtime_stage_container_delete "$cn"; then
          echo "[Error] Failed to stage deletion for backend container '${cn}'." >&2
          return 1
        fi
      done < <(printf '%s' "$backend_container_candidates" | sort -u)
    fi
  else
    if nginx_container_is_managed; then
      if ! remove_container_and_anonymous_volumes "$NGINX_CONTAINER_NAME"; then
        echo "[Error] Failed to remove Nginx container '${NGINX_CONTAINER_NAME}'." >&2
        return 1
      fi
      echo "[Info] Removed Nginx container."
    fi
    if [ -n "$backend_container_candidates" ]; then
      while read -r cn; do
        [ -n "$cn" ] || continue
        if ! remove_container_and_anonymous_volumes "$cn" >/dev/null 2>&1; then
          echo "[Error] Failed to remove backend container '${cn}'." >&2
          return 1
        fi
        echo "[Info] Removed backend container '$cn'."
      done < <(printf '%s' "$backend_container_candidates" | sort -u)
    fi
  fi

  if [ "$started_txn" = true ]; then
    end_transaction_success
    if ! _cleanup_runtime_finalize_staged_deletes; then
      return 1
    fi
  fi
  if [ "$deferred_tmp_cleanup" = true ] && [ -d "$TMP_DIR" ]; then
    safe_rm_rf "$TMP_DIR" "$STATE_DIR"
    echo "[Info] Removed directory $TMP_DIR."
  fi
}
