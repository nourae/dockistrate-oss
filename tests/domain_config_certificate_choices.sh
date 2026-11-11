#!/usr/bin/env bash
# Shared fixture variables are consumed by sourced production modules.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in utils/csv utils/state_csv utils/validators domain_config certs/list_certs \
  cli/arg_choices_misc cli/arg_choices_domain_certificates cli/interactive_dashboard \
  cli/interactive_no_state; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/${module}.sh"
done

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-domain-cert-choices.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
STATE_DIR="$tmp_dir/state"
DOMAINS_DIR="$STATE_DIR/domains"
CERTS_DIR="$STATE_DIR/certs"
BACKEND_PORTS_FILE="$STATE_DIR/backend_ports.csv"
DOMAIN_CONFIG_ACTIVE=true

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  exit 1
}

function cert_created_timestamp() { printf '%s' unavailable; }

for owner in example.com cert-only.example.com; do
  cert_dir="$DOMAINS_DIR/$owner/certs/shared"
  mkdir -p "$cert_dir"
  # Malformed material must stay discoverable for replacement and diagnosis.
  printf '%s\n' 'invalid certificate for listing test' >"$cert_dir/fullchain.pem"
  printf '%s\n' 'provider,port_suffix,source_ref,declared,specification,source_fullchain,source_privkey' 'custom,8443,,yes,,,' >"$cert_dir/certificate.csv"
done
{
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER"
  state_backend_ports_row_port example.com 9443 80 https example.com/shared no off ''
} >"$BACKEND_PORTS_FILE"

choices="$(__arg_choices_cert_path add-port)"
[[ "$choices" == *'example.com/shared|shared | example.com | Custom | 8443,9443 | '* ]] || fail_test 'Canonical reference or usage ports missing.'
[[ "$choices" == *'cert-only.example.com/shared|shared | cert-only.example.com | Custom | 8443 | '* ]] || fail_test 'Certificate-only owner missing.'
owned_line="$(printf '%s\n' "$choices" | sed -n '/^example[.]com\/shared|/p')"
other_line="$(printf '%s\n' "$choices" | sed -n '/^cert-only[.]example[.]com\/shared|/p')"
[[ "$owned_line" == *' | Yes' ]] || fail_test 'Used certificate was marked unused.'
[[ "$other_line" == *' | No' ]] || fail_test 'Same certificate ID under another domain was marked used.'
[[ "$choices" == *'none|Generate self-signed certificate'* ]] || fail_test 'Certificate generation choice missing.'

owners="$(__arg_choices_cert_domains)"
[ "$owners" = "$(printf '%s\n' cert-only.example.com example.com)" ] || fail_test 'Certificate domain enumeration differs.'
suffixes="$(__arg_choices_cert_suffixes_for_domain example.com)"
[[ "$suffixes" == *'8443|8443'* && "$suffixes" == *'9443|9443 (HTTPS mapping)'* ]] || fail_test 'Domain certificate suffix choices are incomplete.'
[ "$(interactive_dashboard_cert_count)" = 2 ] || fail_test 'Dashboard should count domain-owned certificates.'
_interactive_state_has_certs || fail_test 'Certificate actions must remain available without legacy certificate folders.'
listing="$(list_certs)"
used_listing="$(printf '%s\n' "$listing" | sed -n '/^example[.]com\/shared /p')"
other_listing="$(printf '%s\n' "$listing" | sed -n '/^cert-only[.]example[.]com\/shared /p')"
[[ "$used_listing" == *'8443,9443'* && "$used_listing" == *Yes* ]] || fail_test 'Certificate list lost the canonical reference or mapped ports.'
[[ "$other_listing" == *No* ]] || fail_test 'Certificate list confused identical IDs belonging to different owners.'
printf '%s\n' 'provider,port_suffix,source_ref,declared,specification,source_fullchain,source_privkey' 'custom,8443,,no,,,' >"$DOMAINS_DIR/cert-only.example.com/certs/shared/certificate.csv"
choices="$(__arg_choices_cert_path add-port)"
[[ "$choices" != *'cert-only.example.com/shared|'* ]] || fail_test 'Retained material must not reappear in new mapping choices.'
listing="$(list_certs)"
[[ "$listing" == *retained* ]] || fail_test 'Explicit certificate listing should show retained material.'
[[ "$(__arg_choices_cert_domains)" == *cert-only.example.com* ]] || fail_test 'Retained certificate owners must remain selectable for removal.'
[ "$(interactive_dashboard_cert_count)" = 2 ] || fail_test 'Dashboard should count retained material shown by list-certs.'

rm -f "$DOMAINS_DIR/example.com/certs/shared/fullchain.pem" "$DOMAINS_DIR/cert-only.example.com/certs/shared/fullchain.pem"
[ "$(interactive_dashboard_cert_count)" = 0 ] || fail_test 'Dashboard should reflect removed certificates.'
if _interactive_state_has_certs; then fail_test 'Empty certificate inventory should disable certificate removal.'; fi

printf '%s\n' '[tests] domain_config_certificate_choices.sh: PASS'
