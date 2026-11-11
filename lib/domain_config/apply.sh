# shellcheck shell=bash

function _domain_config_ensure_mutation_runtime() {
  if declare -F dockistrate_prepare_runtime >/dev/null 2>&1; then
    dockistrate_prepare_runtime || return 1
  else
    bootstrap_config_runtime || return 1
  fi
}

function _domain_config_selected_changed() {
  local work="${1:-}" root="" domain=""
  root="$(domain_config_root)"
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    _domain_config_same "$work/candidate/$domain/config" "$root/$domain/runtime/applied" || return 0
  done <"$work/selected"
  return 1
}

function _domain_config_apply_locked() (
  local work="${1:-}" target="${2:-}" domain="" path="" started_lock=false security_changed=false
  local DOMAIN_CONFIG_ACTIVE=true DOMAIN_CONFIG_CANDIDATE_ROOT="$work/candidate"
  local DOMAIN_CONFIG_SELECTED_FILE="$work/selected"
  local -a DOMAIN_CONFIG_TRANSACTION_TARGETS=()
  _config_begin_runtime_prep_lock_if_needed started_lock || return 1
  trap '_config_end_runtime_prep_lock_if_started "$started_lock"' EXIT
  rm -rf "$work/candidate" "$work/source-fingerprints" || return 1
  _domain_config_build_candidate "$work" "$target" || return 1
  domain_config_validate_tree "$work/candidate" || return 1
  domain_config_preflight_mtls "$work/candidate" || return 1
  domain_config_runtime_preflight "$work/candidate" || return 1
  security_changed="$(_domain_config_security_changed "$work/candidate")" || return 1
  _domain_config_transaction_targets || return 1
  # New drafts have no applied directory yet, but their runtime/material roots
  # must be removed if the first application fails.
  begin_transaction "apply_domain_config" "${DOMAIN_CONFIG_TRANSACTION_TARGETS[@]}" || return 1
  if [ "${SKIP_DOCKER_CHECKS:-}" != true ]; then
    _nginx_prepare_runtime_rollback "$NGINX_IMAGE" || return 1
    domain_config_runtime_capture_proxy || return 1
  fi
  local SKIP_UPDATE_NGINX_CONFIG=true
  domain_config_provision_certificates "$work/candidate" || return 1
  domain_config_reconcile_backends "$work/candidate" || return 1
  domain_config_compile "$work/candidate" "$work/compiled" || return 1
  _domain_config_publish_cache "$work/compiled" || return 1
  SKIP_UPDATE_NGINX_CONFIG=false
  if [ "$security_changed" = true ]; then
    update_nginx_config_for_security_change || return 1
  else
    update_nginx_config || return 1
  fi
  _domain_config_publish_applied "$work/candidate" "$work/selected" || return 1
  _domain_config_publish_generated || return 1
  _domain_config_mark_cache || return 1
  # Even a file-only edit needs a finalized automatic snapshot. The existing
  # journal defers this request until editable/applied publication is complete.
  create_backup "" ApplyDomainConfig || return 1
  end_transaction_success || return 1
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    printf '[Info] Applied domain configuration: %s\n' "$domain"
    if ! _domain_config_same "$(domain_config_root)/$domain/config" "$work/candidate/$domain/config"; then
      printf '[Info] %s has additional file edits that remain unapplied.\n' "$domain"
    fi
  done <"$work/selected"
)

function apply_domain_config() {
  local target="" dry_run=false work="" status=0
  [ "$#" -ge 1 ] || { _domain_config_error "Usage: apply-domain-config <domain>|--all [--dry-run]"; return 2; }
  _domain_config_prepare || return 1
  target="$(_domain_config_parse_target "$1")" || return 2
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in --dry-run) dry_run=true ;; *) _domain_config_error "Unknown apply option: $1"; return 2 ;; esac
    shift
  done
  if [ "$dry_run" != true ]; then _domain_config_ensure_mutation_runtime || return 1; fi
  _domain_config_workspace work || return 1
  local DOMAIN_CONFIG_SELECTED_FILE="$work/selected"
  if ! _domain_config_build_candidate "$work" "$target"; then
    _domain_config_workspace_remove "$work"; return 1
  fi
  if [ "$dry_run" = true ]; then
    if domain_config_validate_tree "$work/candidate" && domain_config_preflight_mtls "$work/candidate"; then
      _domain_config_preview "$work" || status=$?
    else
      status=1
    fi
  else
    if _domain_config_ensure_mutation_runtime; then
      if ! _domain_config_selected_changed "$work"; then
        # Canonical comparison ignores defaults and presentation. It cannot
        # establish validity: duplicate default rows must still be rejected.
        if ! domain_config_validate_tree "$work/candidate" || ! domain_config_preflight_mtls "$work/candidate"; then
          status=1
        elif declare -F domain_config_runtime_matches >/dev/null 2>&1 && domain_config_runtime_matches "$work/candidate"; then
          printf '[Info] Configuration and runtime are unchanged.\n'
        else
          _domain_config_apply_locked "$work" "$target" || status=$?
        fi
      else
        _domain_config_apply_locked "$work" "$target" || status=$?
      fi
    else
      status=1
    fi
  fi
  _domain_config_workspace_remove "$work" || true
  return "$status"
}
