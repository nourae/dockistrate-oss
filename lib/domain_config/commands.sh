# shellcheck shell=bash

function init_domain_config() {
  local domain="${1:-}" kind=backend root="" destination="" work=""
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --kind) require_option_value "$@" || return 2; kind="$2"; shift 2 ;;
    *) _domain_config_error "Usage: init-domain-config <domain> [--kind backend|alias|dedicated|certificate-only]"; return 2 ;;
    esac
  done
  _domain_config_prepare || return 1
  domain="$(normalize_domain "$domain")"
  _domain_config_validate_name "$domain" || return 2
  case "$kind" in backend | alias | dedicated | certificate-only) ;; *) _domain_config_error "Invalid domain kind: $kind"; return 2 ;; esac
  root="$(domain_config_root)"; destination="$root/$domain/config"
  runtime_state_path_guard_if_declared "$destination" "editable configuration" || return 1
  [ ! -e "$destination" ] || { _domain_config_error "Configuration already exists: $destination"; return 1; }
  # Templates are source-only and deliberately have no runtime side effects.
  _domain_config_workspace work || return 1
  if ! domain_config_write_template "$domain" "$kind" "$work/config"; then
    _domain_config_workspace_remove "$work"; return 1
  fi
  if ! _domain_config_init_publish "$work/config" "$destination" "$domain"; then
    _domain_config_workspace_remove "$work"; return 1
  fi
  _domain_config_workspace_remove "$work"
  printf '[Info] Editable configuration created: %s\n' "$destination"
  printf '[Info] Complete the required values, validate, then apply-domain-config %s.\n' "$domain"
}

function _domain_config_init_publish() (
  local source="$1" destination="$2" domain="$3" started_lock=false
  (umask 077; mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$TMP_DIR") || return 1
  _config_begin_runtime_prep_lock_if_needed started_lock || return 1
  trap '_config_end_runtime_prep_lock_if_started "$started_lock"' EXIT
  # Recover earlier runtime operations with the caller's Docker setting before
  # entering this source-only transaction.
  domain_config_runtime_recover || return 1
  local SKIP_DOCKER_CHECKS=true DOMAIN_CONFIG_ACTIVE=true
  begin_transaction "init_domain_${domain}" "$CONFIG_DIR" || return 1
  [ ! -e "$destination" ] || return 1
  _domain_config_source_publish "$domain" "$source" missing || return 1
  _domain_config_source_verify || return 1
  end_transaction_success
)

function _domain_config_parse_target() {
  local value="${1:-}"
  if [ "$value" = --all ]; then printf '%s\n' "$value"; return 0; fi
  value="$(normalize_domain "$value")"
  _domain_config_validate_name "$value" || return 2
  printf '%s\n' "$value"
}

function validate_domain_config() {
  [ "$#" -eq 1 ] || { _domain_config_error "Usage: validate-domain-config <domain>|--all"; return 2; }
  local target="" work="" status=0
  _domain_config_prepare || return 1
  target="$(_domain_config_parse_target "$1")" || return 2
  _domain_config_workspace work || return 1
  if ! _domain_config_build_candidate "$work" "$target" || ! domain_config_validate_tree "$work/candidate"; then status=1; fi
  _domain_config_workspace_remove "$work" || true
  [ "$status" -ne 0 ] || printf '[Info] Domain configuration is valid: %s\n' "$target"
  return "$status"
}

function _domain_config_preview() {
  local work="${1:-}" domain="" root="" before="" after="" runtime_changes="" changed=false
  local DOMAIN_CONFIG_SELECTED_FILE="$work/selected"
  root="$(domain_config_root)"
  domain_config_runtime_preflight "$work/candidate" || return 1
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    if _domain_config_same "$work/candidate/$domain/config" "$root/$domain/runtime/applied"; then
      printf '%s: configuration unchanged\n' "$domain"
    else
      changed=true
      printf '%s: %s\n' "$domain" "$([ -f "$root/$domain/runtime/applied/domain.csv" ] && printf update || printf create)"
      for after in "$work/candidate/$domain/config"/*.csv; do
        [ -f "$after" ] || continue
        before="$root/$domain/runtime/applied/${after##*/}"
        if [ ! -f "$before" ] || ! cmp -s "$before" "$after"; then printf '  %s\n' "${after##*/}"; fi
      done
      for before in "$root/$domain/runtime/applied"/*.csv; do
        [ -f "$before" ] || continue
        [ -f "$work/candidate/$domain/config/${before##*/}" ] || printf '  Remove settings from %s\n' "${before##*/}"
      done
    fi
  done <"$work/selected"
  if declare -F domain_config_runtime_preview >/dev/null 2>&1; then
    runtime_changes="$(domain_config_runtime_preview "$work/candidate")" || return 1
    if [ -n "$runtime_changes" ]; then printf '%s\n' "$runtime_changes"; changed=true; fi
  fi
  _domain_config_preview_proxy "$work/candidate" "$changed" "$runtime_changes"
}

function _domain_config_preview_proxy() {
  local candidate="$1" changed="$2" changes="${3:-}" path="" rows="" row="" bindings="" expected="" actual="" protocol="" http3="" action=reload security_changed=false
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  security_changed="$(_domain_config_security_changed "$candidate")" || return 1
  if ! _domain_config_generated_ready "$candidate"; then
    changed=true
    printf '  Generated files: refresh per-domain configuration and proxy layout.\n'
  fi
  for path in "$candidate"/*/config; do
    [ -d "$path" ] || continue
    rows="$(_domain_csv_rows "$path/ports.csv")" || return 1
    [ -n "$rows" ] || continue
    while IFS= read -r row; do
      csv_parse_line "$row" || return 1
      protocol=tcp; [ "${CSV_FIELDS[2]}" != udp ] || protocol=udp
      bindings+="${CSV_FIELDS[0]}/$protocol"$'\n'
      if [ "${CSV_FIELDS[2]}" = https ]; then
        if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ]; then
          http3="$(domain_config_port_option "$path" "${CSV_FIELDS[0]}" https http3_enabled off)" || return 1
        else
          http3="${CSV_FIELDS[8]}"
        fi
        if [ "$http3" = on ]; then bindings+="${CSV_FIELDS[0]}/udp"$'\n'; fi
      fi
    done <<<"$rows"
  done
  expected="$(printf '%s' "$bindings" | LC_ALL=C sort -u | xargs)" || return 1
  if [ "${SKIP_DOCKER_CHECKS:-}" = true ]; then
    actual="$(get_all_mapped_port_bindings | tr ' ' '\n' | LC_ALL=C sort -u | xargs)" || return 1
    [ -f "$NGINX_CONFIG_DIR/nginx.conf" ] || action=create
  elif nginx_container_is_managed; then
    actual="$(container_published_port_bindings "$NGINX_CONTAINER_NAME" | tr ' ' '\n' | LC_ALL=C sort -u | xargs)" || return 1
    container_running "$NGINX_CONTAINER_NAME" || action=recreate
  else
    action=create
  fi
  if [ "$action" != create ]; then
    [ "$security_changed" = false ] || action=recreate
    [ "$expected" = "$actual" ] || action=recreate
    case "$changes" in *'certificate '* | *'mTLS authority'*) action=recreate ;; esac
  fi
  if [ "$changed" = false ] && [ "$action" = reload ]; then
    printf '  Proxy: unchanged; no reload required.\n'
  else
    printf '  Proxy: %s with published bindings %s.\n' "$action" "${expected:-none}"
  fi
}
