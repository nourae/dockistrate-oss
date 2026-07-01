#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -x ./dockistrate.sh ]]; then
  echo "[tests] Error: ./dockistrate.sh is not executable. Fix with: chmod +x dockistrate.sh (and commit mode bit)."
  exit 1
fi

TIMEOUT_HELPER="./tests/lib/run_with_timeout.sh"
STATE_SANDBOX_HELPER="./tests/lib/state_sandbox.sh"
TEST_TIMEOUT_SECONDS="${TEST_TIMEOUT_SECONDS:-90}"
TEST_TIMEOUT_PERSISTED_RENDER_SECONDS="${TEST_TIMEOUT_PERSISTED_RENDER_SECONDS:-600}"
TEST_TIMEOUT_INTEGRATION_SECONDS="${TEST_TIMEOUT_INTEGRATION_SECONDS:-1200}"
TEST_TIMEOUT_GRACE_SECONDS="${TEST_TIMEOUT_GRACE_SECONDS:-5}"
TEST_RUN_SUITE="${TEST_RUN_SUITE:-all}"
TEST_SCRIPT_TIMINGS=()

if [[ ! -x "$TIMEOUT_HELPER" ]]; then
  echo "[tests] Error: ${TIMEOUT_HELPER} is not executable." >&2
  exit 1
fi
set +e
"$TIMEOUT_HELPER" --probe
probe_rc=$?
set -e
if [ "$probe_rc" -ne 0 ]; then
  exit "$probe_rc"
fi

if [[ ! -r "$STATE_SANDBOX_HELPER" ]]; then
  echo "[tests] Error: ${STATE_SANDBOX_HELPER} is not readable." >&2
  exit 1
fi

# shellcheck source=tests/lib/state_sandbox.sh
source "$STATE_SANDBOX_HELPER"

function reset_repo_state() {
  dockistrate_test_remove_dir_tree "${ROOT_DIR}/state"
  mkdir -p "${ROOT_DIR}/state"
}

trap dockistrate_test_state_sandbox_restore EXIT
dockistrate_test_state_sandbox "$ROOT_DIR"
export DOCKISTRATE_TEST_STATE_SANDBOX_MANAGED_BY_RUNNER=true

function timeout_seconds_for_script() {
  local script="${1:-}"
  case "$script" in
  tests/persisted_render_validation.sh)
    printf '%s\n' "$TEST_TIMEOUT_PERSISTED_RENDER_SECONDS"
    ;;
  tests/integration/test_cli.sh | tests/integration/test_feature_configs.sh)
    printf '%s\n' "$TEST_TIMEOUT_INTEGRATION_SECONDS"
    ;;
  *)
    printf '%s\n' "$TEST_TIMEOUT_SECONDS"
    ;;
  esac
}

function should_run_script() {
  local script="${1:-}"

  case "$TEST_RUN_SUITE" in
  all)
    return 0
    ;;
  fast)
    case "$script" in
    tests/persisted_render_validation.sh | tests/integration/test_cli.sh | tests/integration/test_feature_configs.sh)
      return 1
      ;;
    *)
      return 0
      ;;
    esac
    ;;
  integration-cli)
    [ "$script" = "tests/integration/test_cli.sh" ]
    ;;
  integration-feature-configs)
    [ "$script" = "tests/integration/test_feature_configs.sh" ]
    ;;
  persisted-render)
    [ "$script" = "tests/persisted_render_validation.sh" ]
    ;;
  *)
    echo "[tests] Error: unsupported TEST_RUN_SUITE '${TEST_RUN_SUITE}'." >&2
    echo "[tests] Supported values: all, fast, integration-cli, integration-feature-configs, persisted-render." >&2
    exit 2
    ;;
  esac
}

function print_slowest_scripts() {
  local limit="${1:-20}"
  local seconds="" script=""
  local timing_file="" printed=0
  [ "${#TEST_SCRIPT_TIMINGS[@]}" -gt 0 ] || return 0

  echo "[tests] Slowest ${limit} test scripts:"
  if ! timing_file="$(mktemp "${TMPDIR:-/tmp}/dockistrate_test_timings.XXXXXX" 2>/dev/null)"; then
    echo "[tests] Warn: unable to create timing summary temp file; skipping slowest-script summary." >&2
    return 0
  fi

  if ! printf '%s\n' "${TEST_SCRIPT_TIMINGS[@]}" | LC_ALL=C sort -t ':' -rn -k1,1 >"$timing_file"; then
    echo "[tests] Warn: unable to sort timing summary; skipping slowest-script summary." >&2
    rm -f "$timing_file"
    return 0
  fi

  while IFS=':' read -r seconds script; do
    [ -n "$script" ] || continue
    echo "[tests] slow ${seconds}s: ${script}"
    printed=$((printed + 1))
    [ "$printed" -lt "$limit" ] || break
  done <"$timing_file"

  rm -f "$timing_file"
  return 0
}

scripts=(
  "tests/function_reference_paths_exist.sh"
  "tests/function_reference_appendix_command_coverage.sh"
  "tests/completion_command_coverage.sh"
  "tests/csv_schema_alignment.sh"
  "tests/cli_command_descriptions_direct_sourcing.sh"
  "tests/completion_update_helpers.sh"
  "tests/lib_eval_usage_guard.sh"
  "tests/interactive_cli_parity.sh"
  "tests/interactive_picker_menu_categories_split.sh"
  "tests/interactive_global_search.sh"
  "tests/interactive_dashboard_summary.sh"
  "tests/interactive_home_screen.sh"
  "tests/add_backend_interactive_prompt_copy.sh"
  "tests/add_backend_port_picker_helper.sh"
  "tests/interactive_add_backend_cert_choices.sh"
  "tests/interactive_recents_favorites.sh"
  "tests/interactive_backtracking_generic_args.sh"
  "tests/interactive_review_before_run.sh"
  "tests/interactive_update_preflight_no_runtime.sh"
  "tests/interactive_no_state_guidance.sh"
  "tests/interactive_disabled_command_rows.sh"
  "tests/interactive_contextual_help.sh"
  "tests/interactive_no_clear_mode.sh"
  "tests/choose_option_context_status_errexit.sh"
  "tests/interactive_status_screen_pause_guard.sh"
  "tests/error_output_stderr_style.sh"
  "tests/run_probe_exit_status.sh"
  "tests/yes_no_prompt_normalization.sh"
  "tests/confirm_prompt_modes.sh"
  "tests/run_with_timeout_helper.sh"
  "tests/lazy_runtime_prep_startup.sh"
  "tests/dependencies_sslkeylog_lazy_build.sh"
  "tests/control_server_tokens.sh"
  "tests/control_server_tokens_transaction_start_failure.sh"
  "tests/nginx_directives_validation.sh"
  "tests/nginx_directives_stream_validation.sh"
  "tests/nginx_directives_module_sourcing_style.sh"
  "tests/nginx_directives_strict_mode.sh"
  "tests/nginx_directives_state_upsert.sh"
  "tests/nginx_directives_interactive_prompt_guard.sh"
  "tests/sslkeylog_helper_single_write_guard.sh"
  "tests/sslkeylog_library_docker_build.sh"
  "tests/recreate_nginx_tls_keylog_build_failure.sh"
  "tests/recreate_nginx_tls_keylog_state_containment.sh"
  "tests/recreate_nginx_post_launch_failure_status.sh"
  "tests/capture_tls_state_guard.sh"
  "tests/start_capture_tls_recreate_state_handling.sh"
  "tests/remove_backend_escaping.sh"
  "tests/docker_exact_name_matching.sh"
  "tests/remove_unused_nginx_networks_exact_matching.sh"
  "tests/docker_mock_rename_semantics.sh"
  "tests/docker_opts_parsing.sh"
  "tests/docker_opts_validation.sh"
  "tests/update_backend_docker_opts_arg_choices.sh"
  "tests/start_nginx_docker_opts_arg_choices.sh"
  "tests/backend_domain_arg_choices.sh"
  "tests/get_arg_spec_nginx_docker_opts_semicolon_safety.sh"
  "tests/arg_metadata.sh"
  "tests/review_command.sh"
  "tests/prompt_args_arg_metadata_rendering.sh"
  "tests/start_nginx_validation_no_global_leak.sh"
  "tests/prompt_args_set_port_redirect_defaults_csv_safety.sh"
  "tests/interactive_port_cert_choice_helpers.sh"
  "tests/prompt_args_add_port_interactive_no_choices_guard.sh"
  "tests/prompt_args_alt_svc_manual_collection_guard.sh"
  "tests/prompt_args_update_port_interactive_picker_flow.sh"
  "tests/prompt_args_cert_picker_flow.sh"
  "tests/prompt_args_generic_backtracking.sh"
  "tests/prompt_args_review_before_run.sh"
  "tests/image_ref_validation.sh"
  "tests/dependencies_systemctl_absent.sh"
  "tests/ports_runtime_lsof_fallback.sh"
  "tests/fix_permissions_tls.sh"
  "tests/permissions_entrypoints_direct_sourcing.sh"
  "tests/access_log_entrypoints_direct_sourcing.sh"
  "tests/global_settings_security_update_direct_sourcing.sh"
  "tests/state_permissions_defaults.sh"
  "tests/fix_permissions_state_hardening.sh"
  "tests/runtime_state_symlink_guard.sh"
  "tests/runtime_state_permissions_non_root_nginx.sh"
  "tests/operator_env_overrides_removed.sh"
  "tests/state_sandbox_restore.sh"
  "tests/nginx_proxy_ownership.sh"
  "tests/http_version_transaction.sh"
  "tests/transaction_locking.sh"
  "tests/transaction_startup_state_cleanup.sh"
  "tests/transaction_backup_reuse_correctness.sh"
  "tests/update_nginx_config_runtime_rollback.sh"
  "tests/update_backend_stop_before_replace_releases_resources.sh"
  "tests/update_backend_commit_failure_preserves_runtime.sh"
  "tests/update_backend_runtime_rollback_identity_guard.sh"
  "tests/remove_backend_regression.sh"
  "tests/remove_backend_decline_preserves_state.sh"
  "tests/remove_backend_transaction_failure.sh"
  "tests/remove_backend_missing_container_after_config.sh"
  "tests/remove_backend_mtls_path_atomic.sh"
  "tests/remove_backend_mtls_rollback_restore_after_delete_failure.sh"
  "tests/dedicated_host_transaction_failure.sh"
  "tests/backend_ports_refresh_header_preservation.sh"
  "tests/security_ip_add_guardrails.sh"
  "tests/security_ip_update_guardrails.sh"
  "tests/security_acl_interactive_scope_fallback_csv_safety.sh"
  "tests/clean_all_regression.sh"
  "tests/clean_all_transaction_failure.sh"
  "tests/clean_all_runtime_rollback_on_commit_failure.sh"
  "tests/runtime_safety_finalize_delete_failure_restores_container.sh"
  "tests/uninstall_all_transaction_failure.sh"
  "tests/uninstall_all_runtime_rollback_on_commit_failure.sh"
  "tests/uninstall_all_lock_order.sh"
  "tests/uninstall_all_safe_delete_guard.sh"
  "tests/certs_timestamp.sh"
  "tests/cert_path_arg_choices_malformed_cert_guard.sh"
  "tests/cert_path_arg_choices_created_date_portability.sh"
  "tests/letsencrypt_cleanup.sh"
  "tests/renew_certs_shared_source_dedupe.sh"
  "tests/renew_certs_copy_failure_preserves_existing_live_copy.sh"
  "tests/backup_name_validation.sh"
  "tests/create_backup_path_guard.sh"
  "tests/backup_archive_checksum.sh"
  "tests/backup_tar_safe_fallbacks.sh"
  "tests/backup_restore_safe_extract.sh"
  "tests/restore_backup_transaction_start_failure.sh"
  "tests/restore_backup_runtime_recovery.sh"
  "tests/state_schema_versioning.sh"
  "tests/update_preflight_standalone_cleanup.sh"
  "tests/update_preflight_no_write.sh"
  "tests/update_preflight_schema_tags.sh"
  "tests/config_bootstrap_split.sh"
  "tests/operator_visibility_policy.sh"
  "tests/visibility_policy_verbose_xtrace.sh"
  "tests/runtime_prep_lock_serialization.sh"
  "tests/save_config_atomic_transactional.sh"
  "tests/config_library_error_contract.sh"
  "tests/config_mutation_transaction_coverage.sh"
  "tests/config_mutation_transaction_inventory.sh"
  "tests/nginx_setting_transaction_rollback.sh"
  "tests/summarize_container_image.sh"
  "tests/config_checksum_sha256.sh"
  "tests/mtls_dir_validation.sh"
  "tests/mtls_input_validation.sh"
  "tests/mtls_post_validation_symlink_swap.sh"
  "tests/mtls_enable_domain_and_openssl_conf.sh"
  "tests/mtls_crl_failure_preserves_existing_crl.sh"
  "tests/mtls_revoke_failure_preserves_client_files.sh"
  "tests/add_backend_client_cert_transaction_failure.sh"
  "tests/remove_backend_client_cert_transaction_failure.sh"
  "tests/revoke_backend_client_cert_transaction_failure.sh"
  "tests/disable_backend_mtls_transaction_failure.sh"
  "tests/enable_backend_mtls_transaction_failure.sh"
  "tests/enable_backend_mtls_transaction_start_failure.sh"
  "tests/replace_backend_client_cert_transaction_failure.sh"
  "tests/replace_backend_ca_transaction_failure.sh"
  "tests/remove_backend_ca_transaction_failure.sh"
  "tests/remove_backend_ca_missing_dir.sh"
  "tests/export_backend_client_p12_failure_preserves_existing_bundle.sh"
  "tests/export_backend_client_p12_rejects_outside_mtls_dir.sh"
  "tests/atomic_write_output_var.sh"
  "tests/state_csv_append_row.sh"
  "tests/header_value_validation.sh"
  "tests/persisted_render_validation.sh"
  "tests/client_ip_value_var.sh"
  "tests/nginx_backend_header_identity_directives.sh"
  "tests/trusted_proxy_render_validation.sh"
  "tests/mark_current_option_literal_values.sh"
  "tests/cli_prompt_rendering_escape_literal.sh"
  "tests/read_lines_into_array_literal_values.sh"
  "tests/cli_choice_line_to_value_label_pipe_commas_guard.sh"
  "tests/security_rules_list_eval_safety.sh"
  "tests/security_rule_expr_semantics.sh"
  "tests/security_rule_metadata_validation.sh"
  "tests/security_rule_selector_name_validation.sh"
  "tests/security_rule_multi_mode_semantics.sh"
  "tests/security_rules_loader_direct_sourcing.sh"
  "tests/security_rules_entrypoints_direct_sourcing.sh"
  "tests/security_rule_add_interactive_collection_guard.sh"
  "tests/security_rule_prompt_mode_default_only.sh"
  "tests/security_rule_update_interactive_replace_collection_guard.sh"
  "tests/logging_entrypoints_direct_sourcing.sh"
  "tests/direct_sourcing_set_u_guards.sh"
  "tests/audit_log_normalization.sh"
  "tests/audit_log_docker_opts_visibility.sh"
  "tests/safe_delete_guards.sh"
  "tests/integration/test_cli.sh"
  "tests/integration/test_feature_configs.sh"
)

failed=0
echo "[tests] Selected suite: ${TEST_RUN_SUITE}"
for script in "${scripts[@]}"; do
  if ! should_run_script "$script"; then
    continue
  fi

  reset_repo_state
  timeout_seconds="$(timeout_seconds_for_script "$script")"
  echo "[tests] Running ${script}"
  if [[ -x "$script" ]]; then
    cmd=("$script")
  else
    cmd=(bash "$script")
  fi

  script_start_epoch="$(date +%s)"
  if "$TIMEOUT_HELPER" "$timeout_seconds" "$TEST_TIMEOUT_GRACE_SECONDS" "$script" -- "${cmd[@]}"; then
    script_status=0
  else
    script_status=$?
  fi
  script_end_epoch="$(date +%s)"
  script_elapsed=$((script_end_epoch - script_start_epoch))
  TEST_SCRIPT_TIMINGS+=("${script_elapsed}:${script}")
  echo "[tests] Elapsed ${script_elapsed}s: ${script}"

  if [ "$script_status" -ne 0 ]; then
    echo "[tests] Failed: ${script}" >&2
    failed=1
  fi
  echo
done

print_slowest_scripts 20

exit "$failed"
