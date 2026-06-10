#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backends/common.sh"

fail=0

assert_equals() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" != "$actual" ]; then
    echo "[Error] ${label}: expected '${expected}', got '${actual}'" >&2
    fail=1
  fi
}

docker() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
  inspect)
    local format="" container=""
    while [ $# -gt 0 ]; do
      case "$1" in
      -f | --format)
        shift
        format="${1:-}"
        ;;
      *)
        container="$1"
        ;;
      esac
      shift || true
    done
    case "$container" in
    backend-no-repodigest)
      # Simulates containers where RepoDigests is unavailable.
      printf '%s\n' "nginx:1.27-alpine|sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
      return 0
      ;;
    backend-with-repodigest)
      printf '%s\n' "nginx:1.28.1|sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      return 0
      ;;
    *)
      return 1
      ;;
    esac
    ;;
  image)
    if [ "${1:-}" != "inspect" ]; then
      return 1
    fi
    shift || true
    local image_format="" image_ref=""
    while [ $# -gt 0 ]; do
      case "$1" in
      -f | --format)
        shift
        image_format="${1:-}"
        ;;
      *)
        image_ref="$1"
        ;;
      esac
      shift || true
    done
    case "$image_ref" in
    nginx:1.27-alpine)
      printf '%s\n' ""
      return 0
      ;;
    sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
      printf '%s\n' "nginx@sha256:1111111111111111111111111111111111111111111111111111111111111111"
      return 0
      ;;
    nginx:1.28.1)
      printf '%s\n' "nginx@sha256:abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdef"
      return 0
      ;;
    *)
      return 1
      ;;
    esac
    ;;
  *)
    return 1
    ;;
  esac
}

result="$(summarize_container_image "backend-no-repodigest")"
assert_equals "nginx:1.27-alpine@sha256:1234567890ab" "$result" "falls back to config image plus ID digest when RepoDigests missing"

result="$(summarize_container_image "backend-with-repodigest")"
assert_equals "nginx@sha256:111111111111" "$result" "prefers digest resolved by container image ID"

if [ "$fail" -eq 0 ]; then
  echo "summarize_container_image checks passed."
fi

exit "$fail"
