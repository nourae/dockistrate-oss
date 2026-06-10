#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  # shellcheck source=../lib/permissions/fix_permissions_cmd.sh
  source "$ROOT_DIR/lib/permissions/fix_permissions_cmd.sh"
  for name in fix_permissions_cmd fix_permissions; do
    if ! declare -F "$name" >/dev/null 2>&1; then
      echo "$name should be available after directly sourcing fix_permissions_cmd.sh" >&2
      exit 1
    fi
  done
'

ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  # shellcheck source=../lib/permissions/fix_permissions.sh
  source "$ROOT_DIR/lib/permissions/fix_permissions.sh"
  for name in fix_permissions _ensure_tls_permissions; do
    if ! declare -F "$name" >/dev/null 2>&1; then
      echo "$name should be available after directly sourcing fix_permissions.sh" >&2
      exit 1
    fi
  done
'

ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  fix_permissions() { :; }
  # shellcheck source=../lib/permissions/fix_permissions_cmd.sh
  source "$ROOT_DIR/lib/permissions/fix_permissions_cmd.sh"
  for name in fix_permissions_cmd fix_permissions _ensure_tls_permissions __dockistrate_fix_permissions_loaded; do
    if ! declare -F "$name" >/dev/null 2>&1; then
      echo "$name should be available after sourcing fix_permissions_cmd.sh with a predeclared fix_permissions stub" >&2
      exit 1
    fi
  done
'

ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  captured_file="$(mktemp)"
  trap "rm -f \"$captured_file\"" EXIT
  fix_permissions() { printf "%s\n" "${1:-}" >"$captured_file"; }
  fix_permissions_certbot_darwin_user() { :; }
  __dockistrate_fix_permissions_loaded() { :; }
  BASE_DIR="/repo-root"
  # shellcheck source=../lib/permissions/fix_permissions_cmd.sh
  source "$ROOT_DIR/lib/permissions/fix_permissions_cmd.sh"

  fix_permissions_cmd default
  if [ "$(cat "$captured_file")" != "default" ]; then
    echo "fix_permissions_cmd should preserve default as a target directory argument" >&2
    exit 1
  fi

  fix_permissions_cmd normal
  if [ "$(cat "$captured_file")" != "normal" ]; then
    echo "fix_permissions_cmd should preserve normal as a target directory argument" >&2
    exit 1
  fi
'

ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  _ensure_tls_permissions() { :; }
  # shellcheck source=../lib/permissions/fix_permissions.sh
  source "$ROOT_DIR/lib/permissions/fix_permissions.sh"
  for name in fix_permissions _ensure_tls_permissions _print_sudo_hint __dockistrate_permissions_common_loaded; do
    if ! declare -F "$name" >/dev/null 2>&1; then
      echo "$name should be available after sourcing fix_permissions.sh with a predeclared _ensure_tls_permissions stub" >&2
      exit 1
    fi
  done
'

echo "Permissions entrypoint direct sourcing checks passed."
