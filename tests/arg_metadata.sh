#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/arg_metadata.sh
source "$ROOT_DIR/lib/utils/validators.sh"
source "$ROOT_DIR/lib/utils/operator_visibility.sh"
source "$ROOT_DIR/lib/cli/arg_metadata.sh"

function assert_eq() {
  local expected="${1:-}" actual="${2:-}" message="${3:-value mismatch}"
  if [ "$expected" != "$actual" ]; then
    printf '[Error] %s: expected <%s>, got <%s>\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_eq "Extra Docker run options" "$(arg_label docker_opts)" "docker_opts label"
assert_eq "Header direction" "$(arg_label req_resp)" "req_resp label"
assert_eq "Header name or off" "$(arg_label header_or_off)" "header_or_off label"
assert_eq "Directive scope" "$(arg_label directive_scope)" "directive_scope label"
assert_eq "Path prefix" "$(arg_label path_prefix)" "path_prefix label"
assert_eq "Alt-Svc" "$(arg_label alt_svc)" "alt_svc label"
assert_eq "Status code" "$(arg_label code)" "code label"
assert_eq "HTTP redirect" "$(arg_label redirect_pref)" "redirect_pref label"
assert_eq "Redirect target port" "$(arg_label redirect_target)" "redirect_target label"
assert_eq "Visibility policy" "$(arg_label visibility_policy)" "visibility_policy label"
assert_eq "unknown arg" "$(arg_label unknown_arg)" "fallback label"

docker_help="$(arg_help add-backend docker_opts)"
if ! grep -Fq "Dockistrate still owns image, name, network, mounts, and published ports" <<<"$docker_help"; then
  echo "[Error] docker_opts help should explain Dockistrate-owned Docker flags." >&2
  exit 1
fi

target_help="$(arg_help add-path-option target)"
assert_eq "Use a port, host:port, or none to keep the route on the mapped backend." "$target_help" "target help"

header_or_off_help="$(arg_help set-client-ip-header header_or_off)"
assert_eq "Use an HTTP header name, or off to disable this forwarded-header setting." "$header_or_off_help" "header_or_off help"

inherit_value_help="$(arg_help set-dedicated-host-inherit value)"
assert_eq "Use yes to inherit the selected setting from the target backend, or no to manage it independently." "$inherit_value_help" "dedicated-host inherit value help"

assert_eq "--cpus 1 --memory 256m" "$(arg_example add-backend docker_opts)" "docker_opts example"
assert_eq "X-Forwarded-For or off" "$(arg_example set-client-ip-header header_or_off)" "header_or_off example"
assert_eq "yes" "$(arg_example set-dedicated-host-inherit value)" "dedicated-host inherit value example"
assert_eq "full" "$(arg_example set-visibility-policy visibility_policy)" "visibility policy example"
assert_eq "leave blank to keep the shown current value" "$(arg_empty_behavior update-backend docker_opts)" "update docker_opts empty behavior"
assert_eq "leave blank for the default yes" "$(arg_empty_behavior set-dedicated-host-inherit value)" "dedicated-host inherit value empty behavior"
assert_eq "Extra Docker run options" "$(arg_review_label docker_opts)" "review label"
assert_eq "selfsigned, letsencrypt, selfsigned/live/example.com_443, or none" "$(arg_example add-backend cert_path)" "add-backend cert_path example"
assert_eq "selfsigned/live/example.com_443 or none" "$(arg_example add-port cert_path)" "generic cert_path example"

add_backend_cert_help="$(arg_help add-backend cert_path)"
if ! grep -Fq "Use selfsigned or letsencrypt to generate one" <<<"$add_backend_cert_help"; then
  echo "[Error] add-backend cert help should mention supported generation aliases." >&2
  exit 1
fi

add_port_cert_help="$(arg_help add-port cert_path)"
if grep -Fq "letsencrypt" <<<"$add_port_cert_help"; then
  echo "[Error] generic cert help should not advertise add-backend-only letsencrypt alias." >&2
  exit 1
fi

if arg_is_sensitive add-backend docker_opts; then
  echo "[Error] docker_opts should stay visible in interactive recents." >&2
  exit 1
fi
for cmd in add-header update-header add-backend-header update-backend-header; do
  if arg_is_sensitive "$cmd" value; then
    echo "[Error] header values for ${cmd} should stay visible in interactive recents." >&2
    exit 1
  fi
done
if arg_is_sensitive add-port domain; then
  echo "[Error] domain should not be marked sensitive." >&2
  exit 1
fi

VISIBILITY_POLICY=redacted
if ! arg_is_sensitive add-backend docker_opts; then
  echo "[Error] docker_opts should be sensitive when visibility policy is redacted." >&2
  exit 1
fi
if arg_is_sensitive add-backend docker_opts ""; then
  echo "[Error] empty docker_opts should remain visible as an explicit clear." >&2
  exit 1
fi
if ! arg_is_sensitive add-backend docker_opts "--env TOKEN=secret"; then
  echo "[Error] non-empty docker_opts values should be sensitive when visibility policy is redacted." >&2
  exit 1
fi
for cmd in add-header update-header add-backend-header update-backend-header; do
  if ! arg_is_sensitive "$cmd" value; then
    echo "[Error] header values for ${cmd} should be sensitive when visibility policy is redacted." >&2
    exit 1
  fi
done
for spec in set-hsts:hsts_value set-backend-hsts:backend_hsts_value set-csp:csp_value set-backend-csp:backend_csp_value; do
  cmd="${spec%%:*}"
  arg="${spec#*:}"
  if ! arg_is_sensitive "$cmd" "$arg"; then
    echo "[Error] ${spec} should be sensitive when visibility policy is redacted." >&2
    exit 1
  fi
done
if arg_is_sensitive set-hsts hsts_value off ||
  arg_is_sensitive set-hsts hsts_value Off ||
  arg_is_sensitive set-csp csp_value off ||
  arg_is_sensitive set-backend-csp backend_csp_value OFF; then
  echo "[Error] HSTS/CSP off values should remain visible as explicit clears." >&2
  exit 1
fi
if arg_is_sensitive update-backend docker_opts "__DOCKER_OPTS_CLEAR__"; then
  echo "[Error] Backend docker opts clear sentinel should remain visible as explicit clear intent." >&2
  exit 1
fi
if ! arg_is_sensitive set-hsts hsts_value "max-age=60"; then
  echo "[Error] HSTS header values should be sensitive when visibility policy is redacted." >&2
  exit 1
fi
if arg_is_sensitive add-port domain; then
  echo "[Error] domain should remain non-sensitive when visibility policy is redacted." >&2
  exit 1
fi
VISIBILITY_POLICY=full

echo "[tests] arg_metadata.sh: PASS"
