#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/nginx.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backends.sh"
# shellcheck source=tests/lib/backend_identity_fixture.sh
source "$ROOT_DIR/tests/lib/backend_identity_fixture.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/tls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/mtls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/http_version.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/headers.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_update_backend_identity_guard.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

rm_log="$TMP_ROOT/remove.log"
rename_log="$TMP_ROOT/rename.log"
: >"$rm_log"
: >"$rename_log"

cname="backend-example.com"
backup_cname="backend-example.com-rollback-123"
owned_replacement_id="$(printf '%064d' 2)"
original_container_id="$(printf '%064d' 1)"
foreign_replacement_id="$(printf '%064d' 3)"
original_token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
STATE_DIR="$TMP_ROOT/state"
mkdir -p "$STATE_DIR"
backend_fixture_seed_labels "$TMP_ROOT/original.labels" "$original_token" example.com "$STATE_DIR"

function container_exists() {
  case "${1:-}" in
  "$cname"|"$backup_cname") return 0 ;;
  *) return 1 ;;
  esac
}

function remove_container_and_anonymous_volumes() {
  printf '%s\n' "${1:-}" >>"$rm_log"
  return 0
}

function docker() {
  local subcommand="${1:-}"
  shift || true
  case "$subcommand" in
  ps)
    printf '%s\n' "$owned_replacement_id"
    return 0
    ;;
  inspect)
    if [ "${3:-}" = "$owned_replacement_id" ]; then
      printf 'unverified\n'
      return 0
    fi
    if [ "${3:-}" = "$original_container_id" ]; then
      if [ "${2:-}" = '{{.Name}}' ]; then
        printf '/%s\n' "$backup_cname"
      else
        backend_fixture_snapshot "$2" "$original_container_id" running "$TMP_ROOT/original.labels"
      fi
      return 0
    fi
    if [ "${1:-}" = "-f" ] && [ "${3:-}" = "$cname" ]; then
      printf '%s\n' "$foreign_replacement_id"
      return 0
    fi
    return 1
    ;;
  rename)
    printf '%s->%s\n' "${1:-}" "${2:-}" >>"$rename_log"
    return 1
    ;;
  esac
  return 0
}

UPDATE_BACKEND_RUNTIME_MODE="replace"
UPDATE_BACKEND_RUNTIME_CNAME="$cname"
UPDATE_BACKEND_RUNTIME_BACKUP_CNAME="$backup_cname"
UPDATE_BACKEND_RUNTIME_REPLACEMENT_ID="$owned_replacement_id"
UPDATE_BACKEND_RUNTIME_BACKUP_ID="$original_container_id"
UPDATE_BACKEND_RUNTIME_TOKEN=0123456789abcdef0123456789abcdef
UPDATE_BACKEND_RUNTIME_DOMAIN=example.com
UPDATE_BACKEND_RUNTIME_OLD_TOKEN="$original_token"

if _update_backend_runtime_rollback_if_needed; then
  echo "[Error] Rollback incorrectly reported success when an unrelated container prevented restoration." >&2
  exit 1
fi

if [ -s "$rm_log" ]; then
  echo "[Error] Rollback removed the canonical backend container even though it no longer matched the transaction-owned replacement ID." >&2
  exit 1
fi

if ! grep -Fq "${original_container_id}->${cname}" "$rename_log"; then
  echo "[Error] Rollback should still attempt to restore the original container by immutable ID." >&2
  exit 1
fi

echo "update_backend rollback skips deleting unrelated replacement containers."
