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
TEST_TIMEOUT_SLOW_SECONDS="${TEST_TIMEOUT_SLOW_SECONDS:-240}"
TEST_TIMEOUT_DOMAIN_CONFIG_SECONDS="${TEST_TIMEOUT_DOMAIN_CONFIG_SECONDS:-600}"
TEST_TIMEOUT_DOMAIN_RECOVERY_SECONDS="${TEST_TIMEOUT_DOMAIN_RECOVERY_SECONDS:-1200}"
# The full render matrix takes about 790s on a single-CPU local machine.
# CI may override the limit for its runners; keep the default bound finite with margin.
TEST_TIMEOUT_PERSISTED_RENDER_SECONDS="${TEST_TIMEOUT_PERSISTED_RENDER_SECONDS:-1200}"
TEST_TIMEOUT_GRACE_SECONDS="${TEST_TIMEOUT_GRACE_SECONDS:-5}"
TEST_RUN_SUITE="${TEST_RUN_SUITE:-all}"
TEST_SCRIPT_TIMINGS=()
SCRIPT_SHARD_ENABLED=false
script_shard_suite=""
script_shard_total=""
script_shard_index=""
if [ "${TEST_FAST_SHARD_TOTAL+x}" = x ] || [ "${TEST_FAST_SHARD_INDEX+x}" = x ]; then
  script_shard_suite=fast
  script_shard_total="${TEST_FAST_SHARD_TOTAL:-}"
  script_shard_index="${TEST_FAST_SHARD_INDEX:-}"
fi
if [ "${TEST_DOMAIN_SHARD_TOTAL+x}" = x ] || [ "${TEST_DOMAIN_SHARD_INDEX+x}" = x ]; then
  if [ -n "$script_shard_suite" ]; then
    echo '[tests] Error: fast and domain-config shard selectors cannot be combined.' >&2
    exit 2
  fi
  script_shard_suite=domain-config
  script_shard_total="${TEST_DOMAIN_SHARD_TOTAL:-}"
  script_shard_index="${TEST_DOMAIN_SHARD_INDEX:-}"
fi
if [ -n "$script_shard_suite" ]; then
  if [ "$TEST_RUN_SUITE" != "$script_shard_suite" ] ||
    [[ ! "$script_shard_total" =~ ^[1-9][0-9]*$ ]] ||
    [[ ! "$script_shard_index" =~ ^(0|[1-9][0-9]*)$ ]] ||
    [ "${#script_shard_total}" -gt 9 ] || [ "${#script_shard_index}" -gt 9 ] ||
    [ "$script_shard_index" -ge "$script_shard_total" ]; then
    echo "[tests] Error: ${script_shard_suite} sharding requires the matching TEST_RUN_SUITE, a positive shard total and an index from 0 to total-1 (decimal, without leading zeroes)." >&2
    exit 2
  fi
  if [ "${TEST_SHARD_TOTAL+x}" = x ] || [ "${TEST_SHARD_INDEX+x}" = x ]; then
    echo '[tests] Error: script-suite shard selectors cannot be combined with integration TEST_SHARD_* selectors.' >&2
    exit 2
  fi
  SCRIPT_SHARD_ENABLED=true
fi
# Selection belongs to this runner, never to nested runners in its test scripts.
unset TEST_FAST_SHARD_TOTAL TEST_FAST_SHARD_INDEX TEST_DOMAIN_SHARD_TOTAL TEST_DOMAIN_SHARD_INDEX

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

active_test_pid=""
cancel_status=0

function cancel_test_run() {
  [ "$cancel_status" -eq 0 ] || return 0
  cancel_status="$1"
  if [ -n "$active_test_pid" ]; then
    kill -TERM "$active_test_pid" >/dev/null 2>&1 || true
  fi
}

function cleanup_test_run() {
  local exit_status=$?
  trap '' INT TERM
  # A canceled test must stop writing before the original state is restored.
  if [ -n "$active_test_pid" ]; then
    kill -TERM "$active_test_pid" >/dev/null 2>&1 || true
    # More than one pending signal can interrupt wait. Do not restore state
    # until the owned child has actually exited, regardless of stale statuses.
    while ! wait "$active_test_pid" 2>/dev/null; do
      kill -0 "$active_test_pid" 2>/dev/null || break
    done
  fi
  dockistrate_test_state_sandbox_restore
  return "$exit_status"
}

function timeout_seconds_for_script() {
  local script="${1:-}"
  case "$script" in
  tests/persisted_render_validation.sh)
    printf '%s\n' "$TEST_TIMEOUT_PERSISTED_RENDER_SECONDS"
    ;;
  tests/domain_config_commit_recovery.sh | tests/domain_config_mtls_integrity.sh | tests/domain_config_header_case_repair.sh)
    printf '%s\n' "$TEST_TIMEOUT_DOMAIN_RECOVERY_SECONDS"
    ;;
  tests/domain_config_stopped_network.sh | tests/domain_config_mtls_backup_portability.sh | tests/domain_config_redirect_defaults.sh | tests/domain_config_path_choice_targets.sh | tests/domain_config_path_removal_cleanup.sh)
    printf '%s\n' "$TEST_TIMEOUT_DOMAIN_CONFIG_SECONDS"
    ;;
  tests/domain_config_remove_alias_policy.sh | tests/domain_config_schema5_migration.sh | tests/domain_config_certificate_backup.sh | tests/domain_config_lifecycle_backup.sh | tests/domain_config_draft_trees.sh | tests/domain_config_restore_runtime.sh | tests/domain_config_restore_directives.sh | tests/domain_config_manual_apply.sh | tests/domain_config_certificate_activation.sh | tests/domain_config_schema4_lifecycle.sh | tests/domain_config_schema3_migration.sh | tests/domain_config_workflow.sh | tests/domain_config_draft_isolation.sh | tests/domain_config_migration.sh | tests/domain_config_migration_unowned.sh | tests/domain_config_apply_failures.sh | tests/domain_config_apply_all.sh | tests/domain_config_backup_restore.sh | tests/domain_config_auto_backup.sh | tests/domain_config_crash_recovery.sh)
    printf '%s\n' "$TEST_TIMEOUT_DOMAIN_CONFIG_SECONDS"
    ;;
  tests/start_capture_tls_launch_rollback.sh | tests/config_mutation_transaction_coverage.sh | tests/nginx_runtime_transaction_lifetime.sh | tests/nginx_directives_validation.sh | tests/nginx_directives_stream_validation.sh | tests/nginx_directives_state_upsert.sh)
    printf '%s\n' "$TEST_TIMEOUT_SLOW_SECONDS"
    ;;
  tests/integration/test_cli.sh)
    printf '%s\n' "${TEST_TIMEOUT_INTEGRATION_SECONDS:-1800}"
    ;;
  tests/integration/test_feature_configs.sh)
    printf '%s\n' "${TEST_TIMEOUT_INTEGRATION_SECONDS:-2400}"
    ;;
  *)
    printf '%s\n' "$TEST_TIMEOUT_SECONDS"
    ;;
  esac
}

# Keep one registered inventory: domain lifecycle tests move together, and new
# domain_config_* scripts automatically join the same suite on both platforms.
function is_domain_config_script() {
  case "${1:-}" in
  tests/domain_config_*.sh | tests/domain_csv_*.sh | tests/shared_csv_records.sh | tests/nginx_certificate_projection_domains.sh)
    return 0
    ;;
  *) return 1 ;;
  esac
}

function should_run_script() {
  local script="${1:-}"


  case "$TEST_RUN_SUITE" in
  all)
    return 0
    ;;
  domain-config)
    is_domain_config_script "$script"
    ;;
  fast)
    if is_domain_config_script "$script"; then return 1; fi
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
    echo "[tests] Supported values: all, fast, domain-config, integration-cli, integration-feature-configs, persisted-render." >&2
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

function run_test_script() {
  local script="$1" shard_index="${2:-}" label="$1"
  local timeout_seconds="" script_start_epoch="" script_end_epoch=""
  local script_status=0 script_elapsed=0
  local -a cmd

  reset_repo_state
  timeout_seconds="$(timeout_seconds_for_script "$script")"
  if [[ -x "$script" ]]; then
    cmd=("$script")
  else
    cmd=(bash "$script")
  fi
  if [ -n "$shard_index" ]; then
    label="${script} shard ${shard_index}/4"
    cmd=(env TEST_SHARD_TOTAL=4 "TEST_SHARD_INDEX=${shard_index}" "${cmd[@]}")
  elif [ -n "${TEST_SHARD_TOTAL:-}" ] || [ -n "${TEST_SHARD_INDEX:-}" ]; then
    case "$script" in
    tests/integration/test_cli.sh | tests/integration/test_feature_configs.sh)
      label="${script} shard ${TEST_SHARD_INDEX:-?}/${TEST_SHARD_TOTAL:-?}"
      ;;
    esac
  fi
  echo "[tests] Running ${label}"

  script_start_epoch="$(date +%s)"
  # Waiting asynchronously lets Bash deliver cancellation traps promptly. Job
  # control keeps INT enabled in the helper, as it is for foreground execution.
  set -m
  "$TIMEOUT_HELPER" "$timeout_seconds" "$TEST_TIMEOUT_GRACE_SECONDS" "$label" -- "${cmd[@]}" &
  active_test_pid=$!
  set +m
  [ "$cancel_status" -eq 0 ] || exit "$cancel_status"
  if wait "$active_test_pid"; then
    script_status=0
  else
    script_status=$?
  fi
  [ "$cancel_status" -eq 0 ] || exit "$cancel_status"
  active_test_pid=""
  script_end_epoch="$(date +%s)"
  script_elapsed=$((script_end_epoch - script_start_epoch))
  TEST_SCRIPT_TIMINGS+=("${script_elapsed}:${label}")
  echo "[tests] Elapsed ${script_elapsed}s: ${label}"

  if [ "$script_status" -ne 0 ]; then
    echo "[tests] Failed: ${label}" >&2
    failed=1
  fi
  echo
}

scripts=(
  "tests/function_reference_paths_exist.sh"
  "tests/function_reference_appendix_command_coverage.sh"
  "tests/completion_command_coverage.sh"
  "tests/completion_option_values.sh"
  "tests/completion_csv_backed_domains.sh"
  "tests/image_pull_mode_parity.sh"
  "tests/csv_schema_alignment.sh"
  "tests/shared_csv_records.sh"
  "tests/csv_formatting.sh"
  "tests/module_loader_ordering.sh"
  "tests/path_split_fastpaths.sh"
  "tests/cli_command_descriptions_direct_sourcing.sh"
  "tests/completion_update_helpers.sh"
  "tests/lib_eval_usage_guard.sh"
  "tests/interactive_cli_parity.sh"
  "tests/domain_config_cli_parity.sh"
  "tests/domain_config_dispatch.sh"
  "tests/domain_config_certificate_choices.sh"
  "tests/domain_config_model.sh"
  "tests/domain_config_header_case_repair.sh"
  "tests/header_case_identity_test.sh"
  "tests/interactive_header_case_identity.sh"
  "tests/domain_config_security_actions.sh"
  "tests/domain_config_schema5_migration.sh"
  "tests/domain_config_schema5_recovery.sh"
  "tests/domain_csv_records.sh"
  "tests/domain_csv_merged_records.sh"
  "tests/domain_config_export_metadata.sh"
  "tests/domain_config_adapter_regressions.sh"
  "tests/domain_config_inventory.sh"
  "tests/domain_config_hidden_inventory.sh"
  "tests/domain_config_status_graph.sh"
  "tests/domain_config_workflow.sh"
  "tests/domain_config_redirect_defaults.sh"
  "tests/domain_config_schema3_backup.sh"
  "tests/domain_config_schema3_recovery.sh"
  "tests/domain_config_schema4_lifecycle.sh"
  "tests/domain_config_schema3_migration.sh"
  "tests/domain_config_migration.sh"
  "tests/domain_config_migration_unowned.sh"
  "tests/domain_config_migration_publication.sh"
  "tests/domain_config_source_publication.sh"
  "tests/domain_config_draft_isolation.sh"
  "tests/domain_config_apply_failures.sh"
  "tests/domain_config_apply_all.sh"
  "tests/domain_config_runtime_journal.sh"
  "tests/domain_config_runtime_drift.sh"
  "tests/domain_config_stopped_network.sh"
  "tests/domain_config_generated_readiness.sh"
  "tests/domain_config_runtime_cleanup.sh"
  "tests/domain_config_crash_recovery.sh"
  "tests/domain_config_commit_recovery.sh"
  "tests/domain_config_acme.sh"
  "tests/domain_config_certificate_paths.sh"
  "tests/domain_config_certificate_removal.sh"
  "tests/domain_config_permissions.sh"
  "tests/domain_config_backup_payload.sh"
  "tests/domain_config_backup_restore.sh"
  "tests/domain_config_mtls_backup_portability.sh"
  "tests/domain_config_mtls_integrity.sh"
  "tests/domain_config_mtls_restore_paths.sh"
  "tests/domain_config_restore_globals.sh"
  "tests/domain_config_restore_directives.sh"
  "tests/domain_config_certificate_activation.sh"
  "tests/domain_config_certificate_backup.sh"
  "tests/domain_config_remove_alias_policy.sh"
  "tests/domain_config_manual_apply.sh"
  "tests/domain_config_nginx_validation.sh"
  "tests/domain_config_restore_runtime.sh"
  "tests/domain_config_draft_trees.sh"
  "tests/domain_config_lifecycle_backup.sh"
  "tests/domain_config_auto_backup.sh"
  "tests/interactive_picker_menu_categories_split.sh"
  "tests/interactive_global_search.sh"
  "tests/interactive_dashboard_summary.sh"
  "tests/interactive_home_screen.sh"
  "tests/add_backend_interactive_prompt_copy.sh"
  "tests/add_backend_port_picker_helper.sh"
  "tests/interactive_add_backend_cert_choices.sh"
  "tests/interactive_recents_favorites.sh"
  "tests/private_operator_storage.sh"
  "tests/permission_startup_overhead.sh"
  "tests/interactive_backtracking_generic_args.sh"
  "tests/interactive_review_before_run.sh"
  "tests/interactive_walkthrough_review.sh"
  "tests/interactive_security_rule_filter.sh"
  "tests/interactive_input_contract.sh"
  "tests/add_backend_interactive_navigation.sh"
  "tests/prompt_args_current_default_selection.sh"
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
  "tests/integration_runner_shards.sh"
  "tests/fast_runner_shards.sh"
  "tests/ci_step_cancellation.sh"
  "tests/interactive_acl_update.sh"
  "tests/interactive_host_choices.sh"
  "tests/interactive_specialized_eof.sh"
  "tests/completion_fresh_shell.sh"
  "tests/review_update_backend_equivalent.sh"
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
  "tests/sslkeylog_helper_runtime.sh"
  "tests/sslkeylog_library_docker_build.sh"
  "tests/recreate_nginx_tls_keylog_build_failure.sh"
  "tests/recreate_nginx_tls_keylog_state_containment.sh"
  "tests/recreate_nginx_post_launch_failure_status.sh"
  "tests/capture_tls_state_guard.sh"
  "tests/start_capture_tls_recreate_state_handling.sh"
  "tests/start_capture_scope_validation.sh"
  "tests/capture_bind_mount_safety.sh"
  "tests/start_capture_tls_launch_rollback.sh"
  "tests/start_capture_tls_failure_diagnostics.sh"
  "tests/remove_backend_escaping.sh"
  "tests/docker_exact_name_matching.sh"
  "tests/add_nginx_networks_standalone.sh"
  "tests/remove_unused_nginx_networks_exact_matching.sh"
  "tests/docker_mock_rename_semantics.sh"
  "tests/docker_opts_parsing.sh"
  "tests/docker_opts_validation.sh"
  "tests/docker_opts_runtime_boundaries.sh"
  "tests/update_backend_docker_opts_arg_choices.sh"
  "tests/start_nginx_docker_opts_arg_choices.sh"
  "tests/backend_domain_arg_choices.sh"
  "tests/get_arg_spec_nginx_docker_opts_semicolon_safety.sh"
  "tests/arg_metadata.sh"
  "tests/review_command.sh"
  "tests/review_option_summaries.sh"
  "tests/prompt_args_arg_metadata_rendering.sh"
  "tests/prompt_args_postprocess_empty_arrays.sh"
  "tests/start_nginx_validation_no_global_leak.sh"
  "tests/prompt_args_set_port_redirect_defaults_csv_safety.sh"
  "tests/set_port_redirect_aliases.sh"
  "tests/interactive_port_cert_choice_helpers.sh"
  "tests/prompt_args_add_port_interactive_no_choices_guard.sh"
  "tests/prompt_args_alt_svc_manual_collection_guard.sh"
  "tests/prompt_args_update_port_interactive_picker_flow.sh"
  "tests/prompt_args_cert_picker_flow.sh"
  "tests/prompt_args_generic_backtracking.sh"
  "tests/prompt_args_review_before_run.sh"
  "tests/image_ref_validation.sh"
  "tests/image_runtime_validation.sh"
  "tests/image_reference_reporting.sh"
  "tests/persisted_settings_validation.sh"
  "tests/persisted_override_validation.sh"
  "tests/persisted_override_cache.sh"
  "tests/persisted_render_transaction_failure.sh"
  "tests/persisted_override_mutation.sh"
  "tests/restore_settings_preflight.sh"
  "tests/nginx_default_image_version_sync.sh"
  "tests/dependencies_systemctl_absent.sh"
  "tests/runtime_bash_only.sh"
  "tests/ports_runtime_lsof_fallback.sh"
  "tests/fix_permissions_tls.sh"
  "tests/private_key_permissions.sh"
  "tests/permission_repair_races.sh"
  "tests/permission_fd_modes.sh"
  "tests/secure_fs.sh"
  "tests/private_key_permissions_cli.sh"
  "tests/private_key_permissions_restore.sh"
  "tests/permissions_entrypoints_direct_sourcing.sh"
  "tests/access_log_entrypoints_direct_sourcing.sh"
  "tests/global_settings_security_update_direct_sourcing.sh"
  "tests/acl_identity_mutation_failures.sh"
  "tests/state_permissions_defaults.sh"
  "tests/fix_permissions_state_hardening.sh"
  "tests/runtime_state_symlink_guard.sh"
  "tests/runtime_state_permissions_non_root_nginx.sh"
  "tests/operator_env_overrides_removed.sh"
  "tests/state_sandbox_restore.sh"
  "tests/nginx_proxy_ownership.sh"
  "tests/nginx_certificate_projection.sh"
  "tests/nginx_certificate_projection_cache.sh"
  "tests/nginx_certificate_projection_rotation.sh"
  "tests/nginx_certificate_projection_sources.sh"
  "tests/nginx_certificate_projection_domains.sh"
  "tests/nginx_certificate_projection_containment.sh"
  "tests/nginx_certificate_projection_metadata.sh"
  "tests/nginx_certificate_projection_mounts.sh"
  "tests/nginx_certificate_projection_groups_empty.sh"
  "tests/nginx_certificate_projection_groups_populated.sh"
  "tests/nginx_certificate_projection_groups_nested.sh"
  "tests/nginx_certificate_projection_runtime.sh"
  "tests/nginx_certificate_projection_runtime_rotation.sh"
  "tests/nginx_certificate_projection_runtime_failure.sh"
  "tests/nginx_certificate_projection_runtime_commit_failure.sh"
  "tests/nginx_certificate_projection_runtime_publication.sh"
  "tests/nginx_certificate_projection_rollback.sh"
  "tests/nginx_certificate_projection_rollback_root.sh"
  "tests/nginx_certificate_projection_rollback_hup.sh"
  "tests/nginx_certificate_projection_rollback_term.sh"
  "tests/nginx_certificate_projection_rollback_early.sh"
  "tests/nginx_certificate_projection_rollback_boundary.sh"
  "tests/nginx_certificate_projection_rollback_state.sh"
  "tests/nginx_certificate_projection_rollback_dependency.sh"
  "tests/http_version_transaction.sh"
  "tests/transaction_locking.sh"
  "tests/transaction_startup_state_cleanup.sh"
  "tests/transaction_backup_reuse_correctness.sh"
  "tests/transaction_rollback_integrity.sh"
  "tests/transaction_snapshot_preflight.sh"
  "tests/transaction_archive_safety.sh"
  "tests/update_nginx_config_runtime_rollback.sh"
  "tests/update_backend_stop_before_replace_releases_resources.sh"
  "tests/update_backend_commit_failure_preserves_runtime.sh"
  "tests/update_backend_runtime_rollback_identity_guard.sh"
  "tests/backend_failed_start_cleanup.sh"
  "tests/backend_replacement_failure_cleanup.sh"
  "tests/interactive_backend_identity_recovery.sh"
  "tests/backend_container_ownership.sh"
  "tests/backend_identity_failure_logging.sh"
  "tests/backend_cleanup_identity.sh"
  "tests/backend_cleanup_recovery_identity.sh"
  "tests/backend_launch_cleanup_identity.sh"
  "tests/remove_backend_regression.sh"
  "tests/remove_backend_decline_preserves_state.sh"
  "tests/remove_all_backends_confirmation.sh"
  "tests/remove_backend_transaction_failure.sh"
  "tests/remove_backend_missing_container_after_config.sh"
  "tests/remove_backend_mtls_path_atomic.sh"
  "tests/remove_backend_mtls_missing_root.sh"
  "tests/remove_backend_mtls_rollback_restore_after_delete_failure.sh"
  "tests/removal_owned_artifacts.sh"
  "tests/dedicated_host_transaction_failure.sh"
  "tests/backend_ports_refresh_header_preservation.sh"
  "tests/remove_all_path_options_validation.sh"
  "tests/alias_acl_identity.sh"
  "tests/acl_deny_precedence.sh"
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
  "tests/selfsigned_certificate_identity.sh"
  "tests/numeric_operands.sh"
  "tests/domain_config_numeric_identity.sh"
  "tests/certbot_pull_transaction_failure.sh"
  "tests/certbot_ownership_trace.sh"
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
  "tests/restore_stat_probe_traps.sh"
  "tests/restore_backup_intake_limits.sh"
  "tests/restore_backup_intake_cli.sh"
  "tests/restore_backup_intake_signals.sh"
  "tests/restore_backup_intake_runtime_cleanup.sh"
  "tests/restore_backup_transaction_start_failure.sh"
  "tests/restore_backup_runtime_recovery.sh"
  "tests/state_schema_versioning.sh"
  "tests/update_preflight_standalone_cleanup.sh"
  "tests/update_preflight_no_write.sh"
  "tests/update_preflight_schema_tags.sh"
  "tests/config_bootstrap_split.sh"
  "tests/config_bootstrap_empty_settings.sh"
  "tests/redaction_command_shapes.sh"
  "tests/raw_directive_visibility.sh"
  "tests/operator_visibility_policy.sh"
  "tests/xtrace_timestamps.sh"
  "tests/visibility_policy_verbose_xtrace.sh"
  "tests/runtime_prep_lock_serialization.sh"
  "tests/save_config_atomic_transactional.sh"
  "tests/saved_settings_permissions.sh"
  "tests/saved_settings_permissions_cli.sh"
  "tests/saved_settings_permissions_restore.sh"
  "tests/config_library_error_contract.sh"
  "tests/config_mutation_transaction_coverage.sh"
  "tests/config_mutation_transaction_inventory.sh"
  "tests/nginx_setting_transaction_rollback.sh"
  "tests/nginx_runtime_transaction_lifetime.sh"
  "tests/summarize_container_image.sh"
  "tests/config_checksum_sha256.sh"
  "tests/mtls_dir_validation.sh"
  "tests/mtls_owner_binding.sh"
  "tests/mtls_input_validation.sh"
  "tests/mtls_post_validation_symlink_swap.sh"
  "tests/mtls_enable_domain_and_openssl_conf.sh"
  "tests/mtls_state_integrity.sh"
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
  "tests/redirect_defaults_validation.sh"
  "tests/persisted_render_validation.sh"
  "tests/client_ip_value_var.sh"
  "tests/nginx_backend_header_identity_directives.sh"
  "tests/trusted_proxy_render_validation.sh"
  "tests/mark_current_option_literal_values.sh"
  "tests/cli_prompt_rendering_escape_literal.sh"
  "tests/read_lines_into_array_literal_values.sh"
  "tests/cli_choice_line_to_value_label_pipe_commas_guard.sh"
  "tests/interactive_path_choices.sh"
  "tests/domain_config_path_choice_targets.sh"
  "tests/path_directive_cleanup_selectors.sh"
  "tests/domain_config_path_removal_cleanup.sh"
  "tests/security_rules_list_eval_safety.sh"
  "tests/security_rule_expr_semantics.sh"
  "tests/security_rule_metadata_validation.sh"
  "tests/security_rule_selector_name_validation.sh"
  "tests/security_rule_host_targets.sh"
  "tests/security_rule_multi_mode_semantics.sh"
  "tests/security_rule_host_identity.sh"
  "tests/security_rule_action_render.sh"
  "tests/security_rule_actions_cli.sh"
  "tests/security_rule_actions_interactive.sh"
  "tests/security_rules_loader_direct_sourcing.sh"
  "tests/security_rules_entrypoints_direct_sourcing.sh"
  "tests/security_rule_add_exact_arity.sh"
  "tests/security_rule_add_interactive_collection_guard.sh"
  "tests/security_rule_prompt_mode_default_only.sh"
  "tests/security_rule_update_interactive_replace_collection_guard.sh"
  "tests/logging_entrypoints_direct_sourcing.sh"
  "tests/direct_sourcing_set_u_guards.sh"
  "tests/audit_log_normalization.sh"
  "tests/audit_log_docker_opts_visibility.sh"
  "tests/safe_delete_guards.sh"
  "tests/literal_path_identity.sh"
  "tests/runtime_path_assignment.sh"
  "tests/integration/test_cli.sh"
  "tests/integration/test_feature_configs.sh"
)

# Select before opening the sandbox so invalid or empty shards cannot move
# existing state. Ordinals count only eligible scripts, in registration order.
selected_scripts=()
script_ordinal=0
for script in "${scripts[@]}"; do
  if ! should_run_script "$script"; then continue; fi
  if [ "$SCRIPT_SHARD_ENABLED" = true ]; then
    selected_index=$((script_ordinal % script_shard_total))
    script_ordinal=$((script_ordinal + 1))
    [ "$selected_index" -eq "$script_shard_index" ] || continue
  fi
  selected_scripts+=("$script")
done
if [ "$SCRIPT_SHARD_ENABLED" = true ] && [ "${#selected_scripts[@]}" -eq 0 ]; then
  echo "[tests] Error: ${script_shard_suite} shard selected no test scripts." >&2
  exit 2
fi

trap 'cancel_test_run 130' INT
trap 'cancel_test_run 143' TERM
trap cleanup_test_run EXIT
dockistrate_test_state_sandbox "$ROOT_DIR"
export DOCKISTRATE_TEST_STATE_SANDBOX_MANAGED_BY_RUNNER=true

failed=0
echo "[tests] Selected suite: ${TEST_RUN_SUITE}"
if [ "$SCRIPT_SHARD_ENABLED" = true ]; then
  echo "[tests] ${script_shard_suite} shard ${script_shard_index}/${script_shard_total}: ${#selected_scripts[@]}/${script_ordinal} scripts"
fi
for script in "${selected_scripts[@]+"${selected_scripts[@]}"}"; do
  [ "$cancel_status" -eq 0 ] || exit "$cancel_status"

  case "$script" in
  tests/integration/test_cli.sh | tests/integration/test_feature_configs.sh)
    # Local defaults cover the same four shards as CI, sequentially so they do
    # not compete for the shared state tree or a small machine's CPU. Explicit
    # shard selection retains the single-shard behavior used by CI and reruns.
    if [ -z "${TEST_SHARD_TOTAL:-}" ] && [ -z "${TEST_SHARD_INDEX:-}" ]; then
      for shard_index in 0 1 2 3; do
        [ "$cancel_status" -eq 0 ] || exit "$cancel_status"
        run_test_script "$script" "$shard_index"
      done
      continue
    fi
    ;;
  esac
  run_test_script "$script"
done

[ "$cancel_status" -eq 0 ] || exit "$cancel_status"
print_slowest_scripts 20
[ "$cancel_status" -eq 0 ] || exit "$cancel_status"

exit "$failed"
