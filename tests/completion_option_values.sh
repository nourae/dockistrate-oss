#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

__dockistrate_completion_handlers=()

# shellcheck source=../completion/commands/_dockistrate_complete_option_values.sh
. "$ROOT_DIR/completion/commands/_dockistrate_complete_option_values.sh"

assert_compreply() {
  local label="$1"
  local expected="$2"
  local actual="${COMPREPLY[*]-}"

  if [ "$actual" != "$expected" ]; then
    echo "[Error] $label completion mismatch." >&2
    echo "[Error] Expected: $expected" >&2
    echo "[Error] Actual:   $actual" >&2
    exit 1
  fi
}

run_add_acl_completion() {
  cur="$1"
  prev="$2"
  cword="$3"
  words=(dockistrate.sh add-acl example.com)
  COMPREPLY=()

  if ! _dockistrate_complete_option_values add-acl; then
    echo "[Error] add-acl completion handler did not handle cword=$cword." >&2
    exit 1
  fi
}

if [ "${#__dockistrate_completion_handlers[@]}" -ne 1 ]; then
  echo "[Error] Expected option-value completion handler to be registered." >&2
  exit 1
fi

run_add_acl_completion "" "example.com" 3
assert_compreply "add-acl scope" "l7 l3 both"

run_add_acl_completion "b" "example.com" 3
assert_compreply "add-acl partial scope" "both"

run_add_acl_completion "" "l7" 4
assert_compreply "add-acl action" "allow deny"

function run_capture_completion() {
  cur="$1"
  prev="$2"
  cword=3
  # Completion helpers share the dispatcher words array.
  # shellcheck disable=SC2034
  words=(dockistrate.sh start-capture "$prev")
  COMPREPLY=()
  _dockistrate_complete_option_values start-capture || {
    echo "[Error] start-capture option-value completion was not handled." >&2
    exit 1
  }
}

run_capture_completion "" --scope
assert_compreply "capture canonical scopes" "all backends clients clients-backends"
run_capture_completion cli --scope
assert_compreply "capture partial scope" "clients clients-backends"
run_capture_completion -- start-capture
assert_compreply "capture flags" "--scope --backends --clients --folder --tls-decrypt"
run_capture_completion 198.51.100. --clients
assert_compreply "capture client value stays literal" ""
run_capture_completion "" --backends
assert_compreply "capture backends without domain helper" ""
function __dockistrate_complete_backend_domains() {
  COMPREPLY=(api.example.test other.example.test)
}
run_capture_completion "" --backends
assert_compreply "capture configured backend helper" "api.example.test other.example.test"

echo "[tests] completion_option_values.sh: PASS"
