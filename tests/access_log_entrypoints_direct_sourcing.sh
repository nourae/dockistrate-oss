#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.access-log-entrypoints.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  # shellcheck source=../lib/access_log.sh
  source "$ROOT_DIR/lib/access_log.sh"

  if ! is_valid_log_field "\$remote_addr"; then
    echo "Expected direct sourcing lib/access_log.sh to load is_valid_log_field under strict mode." >&2
    exit 1
  fi

  if is_valid_log_field "bad;field"; then
    echo "Expected direct sourcing lib/access_log.sh to preserve log field validation behavior." >&2
    exit 1
  fi
'

STATE_ROOT="$TMP_ROOT/list" ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  CONFIG_DIR="$STATE_ROOT/config"
  ACCESS_LOG_FIELDS_FILE="$CONFIG_DIR/access_log_fields.csv"

  # shellcheck source=../lib/utils/validators.sh
  source "$ROOT_DIR/lib/utils/validators.sh"
  # shellcheck source=../lib/utils/csv.sh
  source "$ROOT_DIR/lib/utils/csv.sh"
  # shellcheck source=../lib/utils/fs.sh
  source "$ROOT_DIR/lib/utils/fs.sh"
  # shellcheck source=../lib/utils/state_csv.sh
  source "$ROOT_DIR/lib/utils/state_csv.sh"
  # shellcheck source=../lib/access_log/list_log_fields.sh
  source "$ROOT_DIR/lib/access_log/list_log_fields.sh"

  output="$(list_log_fields)"
  case "$output" in
  *"1:  \$realip_remote_addr"*) ;;
  *)
    echo "Expected direct sourcing list_log_fields.sh to seed and print default access log fields." >&2
    exit 1
    ;;
  esac

  if [ "$(awk "END { print NR }" "$ACCESS_LOG_FIELDS_FILE")" -ne 9 ]; then
    echo "Expected list_log_fields to seed 8 default access log fields." >&2
    exit 1
  fi
'

STATE_ROOT="$TMP_ROOT/add" ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  CONFIG_DIR="$STATE_ROOT/config"
  ACCESS_LOG_FIELDS_FILE="$CONFIG_DIR/access_log_fields.csv"

  # shellcheck source=../lib/utils/validators.sh
  source "$ROOT_DIR/lib/utils/validators.sh"
  # shellcheck source=../lib/utils/csv.sh
  source "$ROOT_DIR/lib/utils/csv.sh"
  # shellcheck source=../lib/utils/fs.sh
  source "$ROOT_DIR/lib/utils/fs.sh"
  # shellcheck source=../lib/utils/state_csv.sh
  source "$ROOT_DIR/lib/utils/state_csv.sh"

  function _config_begin_transaction_if_needed() {
    local started_var="${1:-}"
    printf -v "$started_var" "%s" "false"
  }

  function _config_end_transaction_if_started() {
    :
  }

  function create_backup() {
    :
  }

  function create_nginx_config() {
    :
  }

  function update_nginx_config() {
    :
  }

  # shellcheck source=../lib/access_log/add_log_field.sh
  source "$ROOT_DIR/lib/access_log/add_log_field.sh"

  add_log_field "\$http_x_request_id" 2 >/dev/null

  inserted_line="$(sed -n "3p" "$ACCESS_LOG_FIELDS_FILE" | tr -d "\r")"
  if [ "$inserted_line" != "\$http_x_request_id" ]; then
    echo "Expected direct sourcing add_log_field.sh to insert the new field at the requested position." >&2
    exit 1
  fi

  output="$(list_log_fields)"
  case "$output" in
  *"2: [request] \$http_x_request_id"*) ;;
  *)
    echo "Expected direct sourcing add_log_field.sh to load list_log_fields and report the inserted field." >&2
    exit 1
    ;;
  esac
'

echo "Access log entrypoint direct sourcing checks passed."
