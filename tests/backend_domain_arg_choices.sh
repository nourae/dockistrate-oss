#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"
# shellcheck source=../lib/cli/arg_choices_misc.sh
source "$ROOT_DIR/lib/cli/arg_choices_misc.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-backend-domain-choices.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

BACKEND_PORTS_FILE="${tmp_dir}/backend_ports.csv"
{
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER"
  state_backend_ports_row_backend "beta.example.com" "backend-beta.example.com:8080" "dockistrate-net"
  state_backend_ports_row_backend "alpha.example.com" "backend-alpha.example.com:8080" "dockistrate-net"
  state_backend_ports_row_port "alpha.example.com" "80" "8080" "http" "none" "no" "off" ""
} >"$BACKEND_PORTS_FILE"

expected_domains="$(printf '%s\n' "alpha.example.com" "beta.example.com")"
domain_choices="$(__arg_choices_backend_domains_all)"
if [ "$domain_choices" != "$expected_domains" ]; then
  echo "[Error] Expected all backend domain choices, got:" >&2
  printf '%s\n' "$domain_choices" >&2
  exit 1
fi

mtls_choices="$(__arg_choices_domain "enable-backend-mtls")"
if [ "$mtls_choices" != "$expected_domains" ]; then
  echo "[Error] enable-backend-mtls domain choices should use all backend domains." >&2
  printf '%s\n' "$mtls_choices" >&2
  exit 1
fi

remove_all_choices="$(__arg_choices_domain "remove-all-path-options")"
expected_remove_all="$(printf '%s\n' "__ALL__|All domains" "alpha.example.com" "beta.example.com")"
if [ "$remove_all_choices" != "$expected_remove_all" ]; then
  echo "[Error] remove-all-path-options choices should include all-domain sentinel plus backend domains." >&2
  printf '%s\n' "$remove_all_choices" >&2
  exit 1
fi

echo "[tests] backend_domain_arg_choices.sh: PASS"
