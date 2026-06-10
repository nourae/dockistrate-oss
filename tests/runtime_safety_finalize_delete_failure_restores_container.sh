#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/clean_uninstall/runtime_safety.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_runtime_finalize_restore.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

docker_log_file="$TMP_ROOT/docker_runtime_finalize_restore.log"
first_container_name="backend-example-one"
second_container_name="backend-example-two"
test_container_names=(
  "$first_container_name"
  "$second_container_name"
)
active_meta_files=(
  "$TMP_ROOT/backend_example_one.active.meta"
  "$TMP_ROOT/backend_example_two.active.meta"
)
backup_meta_files=(
  "$TMP_ROOT/backend_example_one.backup.meta"
  "$TMP_ROOT/backend_example_two.backup.meta"
)

function write_container_meta() {
  local file="${1:-}" exists="${2:-false}" name="${3:-}" status="${4:-}"
  {
    printf 'exists=%s\n' "$exists"
    printf 'name=%s\n' "$name"
    printf 'status=%s\n' "$status"
  } >"$file"
}

function read_container_meta() {
  local file="${1:-}" key="${2:-}"
  [ -f "$file" ] || return 1
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

function _container_slot_for_original() {
  local original="${1:-}" index=0

  while [ "$index" -lt "${#test_container_names[@]}" ]; do
    if [ "$original" = "${test_container_names[$index]}" ]; then
      printf '%s\n' "$index"
      return 0
    fi
    index=$((index + 1))
  done

  return 1
}

function _active_meta_file_for_original() {
  local original="${1:-}" slot=""
  if ! slot="$(_container_slot_for_original "$original" 2>/dev/null)"; then
    return 1
  fi

  printf '%s\n' "${active_meta_files[$slot]}"
}

function _backup_meta_file_for_original() {
  local original="${1:-}" slot=""
  if ! slot="$(_container_slot_for_original "$original" 2>/dev/null)"; then
    return 1
  fi

  printf '%s\n' "${backup_meta_files[$slot]}"
}

function _find_original_name_for_candidate() {
  local candidate="${1:-}" original="" backup_name="" index=0

  while [ "$index" -lt "${#test_container_names[@]}" ]; do
    original="${test_container_names[$index]}"
    if [ "$candidate" = "$original" ]; then
      printf '%s\n' "$original"
      return 0
    fi

    backup_name="$(read_container_meta "${backup_meta_files[$index]}" name || true)"
    if [ -n "$backup_name" ] && [ "$candidate" = "$backup_name" ]; then
      printf '%s\n' "$original"
      return 0
    fi
    index=$((index + 1))
  done

  return 1
}

write_container_meta "${active_meta_files[0]}" "true" "$first_container_name" "running"
write_container_meta "${backup_meta_files[0]}" "false" "" ""
write_container_meta "${active_meta_files[1]}" "true" "$second_container_name" "running"
write_container_meta "${backup_meta_files[1]}" "false" "" ""

function container_exists() {
  local candidate="${1:-}" original="" active_meta="" backup_meta="" backup_name=""

  if ! original="$(_find_original_name_for_candidate "$candidate" 2>/dev/null)"; then
    return 1
  fi

  active_meta="$(_active_meta_file_for_original "$original")"
  if [ "$candidate" = "$original" ]; then
    [ "$(read_container_meta "$active_meta" exists || true)" = "true" ]
    return
  fi

  backup_meta="$(_backup_meta_file_for_original "$original")"
  backup_name="$(read_container_meta "$backup_meta" name || true)"
  [ -n "$backup_name" ] || return 1
  [ "$(read_container_meta "$backup_meta" exists || true)" = "true" ]
}

function container_running() {
  local candidate="${1:-}" original="" active_meta="" backup_meta="" backup_name=""

  if ! original="$(_find_original_name_for_candidate "$candidate" 2>/dev/null)"; then
    return 1
  fi

  active_meta="$(_active_meta_file_for_original "$original")"
  if [ "$candidate" = "$original" ] && [ "$(read_container_meta "$active_meta" exists || true)" = "true" ]; then
    [ "$(read_container_meta "$active_meta" status || true)" = "running" ]
    return
  fi

  backup_meta="$(_backup_meta_file_for_original "$original")"
  backup_name="$(read_container_meta "$backup_meta" name || true)"
  if [ -n "$backup_name" ] && [ "$candidate" = "$backup_name" ] && [ "$(read_container_meta "$backup_meta" exists || true)" = "true" ]; then
    [ "$(read_container_meta "$backup_meta" status || true)" = "running" ]
    return
  fi

  return 1
}

function remove_container_and_anonymous_volumes() {
  local candidate="${1:-}" original="" active_meta="" backup_meta="" backup_name=""
  printf 'subcommand=rm -f -v %s\n' "$candidate" >>"$docker_log_file"

  if [ "$candidate" = "$first_container_name" ]; then
    return 1
  fi

  if ! original="$(_find_original_name_for_candidate "$candidate" 2>/dev/null)"; then
    return 1
  fi

  active_meta="$(_active_meta_file_for_original "$original")"
  if [ "$candidate" = "$original" ] && [ "$(read_container_meta "$active_meta" exists || true)" = "true" ]; then
    write_container_meta "$active_meta" "false" "$original" ""
    return 0
  fi

  backup_meta="$(_backup_meta_file_for_original "$original")"
  backup_name="$(read_container_meta "$backup_meta" name || true)"
  if [ -n "$backup_name" ] && [ "$candidate" = "$backup_name" ] && [ "$(read_container_meta "$backup_meta" exists || true)" = "true" ]; then
    write_container_meta "$backup_meta" "false" "$backup_name" ""
    return 0
  fi

  return 1
}

function docker() {
  if [ "$#" -gt 1 ]; then
    printf 'subcommand=%s %s\n' "$1" "${*:2}" >>"$docker_log_file"
  else
    printf 'subcommand=%s\n' "$1" >>"$docker_log_file"
  fi

  case "${1:-}" in
  rename)
    local src="${2:-}" dest="${3:-}" original=""
    local active_meta="" backup_meta="" active_exists="" active_status=""
    local backup_name="" backup_exists="" backup_status=""

    if ! original="$(_find_original_name_for_candidate "$src" 2>/dev/null)"; then
      return 1
    fi

    active_meta="$(_active_meta_file_for_original "$original")"
    backup_meta="$(_backup_meta_file_for_original "$original")"
    active_exists="$(read_container_meta "$active_meta" exists || true)"
    active_status="$(read_container_meta "$active_meta" status || true)"
    backup_name="$(read_container_meta "$backup_meta" name || true)"
    backup_exists="$(read_container_meta "$backup_meta" exists || true)"
    backup_status="$(read_container_meta "$backup_meta" status || true)"

    if [ "$src" = "$original" ]; then
      [ "$active_exists" = "true" ] || return 1
      [ "$backup_exists" = "false" ] || return 1
      write_container_meta "$backup_meta" "true" "$dest" "$active_status"
      write_container_meta "$active_meta" "false" "$original" ""
      return 0
    fi

    if [ -n "$backup_name" ] && [ "$src" = "$backup_name" ] && [ "$dest" = "$original" ]; then
      [ "$backup_exists" = "true" ] || return 1
      [ "$active_exists" = "false" ] || return 1
      write_container_meta "$active_meta" "true" "$original" "$backup_status"
      write_container_meta "$backup_meta" "false" "$backup_name" ""
      return 0
    fi

    return 1
    ;;
  stop)
    local target="${2:-}" original="" backup_meta="" backup_name="" backup_exists=""

    if ! original="$(_find_original_name_for_candidate "$target" 2>/dev/null)"; then
      return 1
    fi

    backup_meta="$(_backup_meta_file_for_original "$original")"
    backup_name="$(read_container_meta "$backup_meta" name || true)"
    backup_exists="$(read_container_meta "$backup_meta" exists || true)"
    if [ -n "$backup_name" ] && [ "$target" = "$backup_name" ] && [ "$backup_exists" = "true" ]; then
      write_container_meta "$backup_meta" "true" "$backup_name" "exited"
      return 0
    fi
    return 1
    ;;
  start)
    local target="${2:-}" original="" active_meta=""

    if ! original="$(_find_original_name_for_candidate "$target" 2>/dev/null)"; then
      return 1
    fi

    active_meta="$(_active_meta_file_for_original "$original")"
    if [ "$target" = "$original" ] && [ "$(read_container_meta "$active_meta" exists || true)" = "true" ]; then
      write_container_meta "$active_meta" "true" "$original" "running"
      return 0
    fi
    return 1
    ;;
  *)
    return 1
    ;;
  esac
}

for container_name in "${test_container_names[@]}"; do
  if ! _cleanup_runtime_stage_container_delete "$container_name"; then
    echo "[Error] Failed to stage runtime container '${container_name}' for finalize failure coverage." >&2
    exit 1
  fi
done

set +e
output_file="$TMP_ROOT/finalize.output"
_cleanup_runtime_finalize_staged_deletes >"$output_file" 2>&1
status=$?
set -e

output="$(cat "$output_file")"

if [ "$status" -eq 0 ]; then
  echo "[Error] Staged delete finalization succeeded unexpectedly." >&2
  exit 1
fi

if ! grep -Fq "Failed to permanently remove staged cleanup container '${first_container_name}'." <<<"$output"; then
  echo "[Error] Finalize failure output did not mention the restored original container name." >&2
  exit 1
fi

for meta_file in "${active_meta_files[@]}"; do
  if [ "$(read_container_meta "$meta_file" exists || true)" != "true" ]; then
    echo "[Error] Finalize failure did not restore every original runtime container." >&2
    exit 1
  fi
  if [ "$(read_container_meta "$meta_file" status || true)" != "running" ]; then
    echo "[Error] Finalize failure did not restart every restored runtime container." >&2
    exit 1
  fi
done

for meta_file in "${backup_meta_files[@]}"; do
  if [ "$(read_container_meta "$meta_file" exists || true)" = "true" ]; then
    echo "[Error] Finalize failure left a staged rollback container behind." >&2
    exit 1
  fi
done

if [ "${CLEANUP_RUNTIME_DELETE_STATE_INITIALIZED:-false}" = "true" ]; then
  echo "[Error] Finalize failure left staged delete state initialized." >&2
  exit 1
fi

if [ -n "${ROLLBACK_PRE_HOOK:-}" ]; then
  echo "[Error] Finalize failure left the staged delete rollback hook registered." >&2
  exit 1
fi

first_rollback_name="$(sed -n "s/^subcommand=rename ${first_container_name} \\(${first_container_name}-rollback-[0-9-][0-9-]*\\)$/\\1/p" "$docker_log_file" | head -n 1)"
second_rollback_name="$(sed -n "s/^subcommand=rename ${second_container_name} \\(${second_container_name}-rollback-[0-9-][0-9-]*\\)$/\\1/p" "$docker_log_file" | head -n 1)"

if [ -z "$first_rollback_name" ] || [ -z "$second_rollback_name" ]; then
  echo "[Error] Failed to discover the staged rollback container names during finalize failure coverage." >&2
  exit 1
fi

for expected in \
  "subcommand=stop $first_rollback_name" \
  "subcommand=stop $second_rollback_name" \
  "subcommand=rename $first_rollback_name $first_container_name" \
  "subcommand=rename $second_rollback_name $second_container_name" \
  "subcommand=rm -f -v $first_container_name" \
  "subcommand=start $first_container_name" \
  "subcommand=start $second_container_name"; do
  if ! grep -Fq "$expected" "$docker_log_file"; then
    echo "[Error] Missing expected finalize failure recovery operation: $expected" >&2
    exit 1
  fi
done

if grep -Fq "subcommand=rm -f -v $second_container_name" "$docker_log_file"; then
  echo "[Error] Finalize failure should restore later staged containers instead of removing them." >&2
  exit 1
fi

printf 'Runtime safety finalization restores all staged containers after a delete failure.\n'
