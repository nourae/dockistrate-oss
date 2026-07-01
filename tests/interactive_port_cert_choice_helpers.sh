#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/arg_choices_misc.sh
source "$ROOT_DIR/lib/cli/arg_choices_misc.sh"
# shellcheck source=../lib/cli/arg_choices_images.sh
source "$ROOT_DIR/lib/cli/arg_choices_images.sh"
# shellcheck source=../lib/cli/arg_choices_protocols.sh
source "$ROOT_DIR/lib/cli/arg_choices_protocols.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_interactive_port_cert_choices.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

CERTS_DIR="${tmp_dir}/certs"
NGINX_HTTP_CONF_DIR="${tmp_dir}/nginx"
BACKEND_PORTS_FILE="${tmp_dir}/backend_ports.csv"
mkdir -p "$CERTS_DIR/selfsigned/live/example.test_9443" "$CERTS_DIR/custom/live/example.test_9444" "$NGINX_HTTP_CONF_DIR"
printf 'dummy cert\n' >"$CERTS_DIR/selfsigned/live/example.test_9443/fullchain.pem"
printf 'dummy cert\n' >"$CERTS_DIR/custom/live/example.test_9444/fullchain.pem"

cat >"$BACKEND_PORTS_FILE" <<EOF_PORTS
${STATE_BACKEND_PORTS_HEADER}
backend,example.test,172.30.0.2:8080,dockistrate-net,,,,,,,,,,,,,,,,,
port,example.test,,,,,80,8080,http,none,no,off,,off,auto,,,,,,
port,example.test,,,,,8443,9443,https,selfsigned/live/example.test_8443,no,off,,off,auto,,,,,,
backend,other.test,172.30.0.3:9000,dockistrate-net,,,,,,,,,,,,,,,,,
port,other.test,,,,,8081,9000,http,none,no,off,,off,auto,,,,,,
EOF_PORTS

CURRENT_ARGS=(example.test)
update_port_choices="$(__arg_choices_nginx_port update-port)"
if ! grep -Fq '80|80 -> 8080 proto=http ws=no cert=none' <<<"$update_port_choices"; then
  echo "[Error] update-port choices should include the selected domain HTTP mapping." >&2
  printf '%s\n' "$update_port_choices" >&2
  exit 1
fi
if ! grep -Fq '8443|8443 -> 9443 proto=https ws=no cert=selfsigned/live/example.test_8443' <<<"$update_port_choices"; then
  echo "[Error] update-port choices should include the selected domain HTTPS mapping." >&2
  printf '%s\n' "$update_port_choices" >&2
  exit 1
fi
if grep -Fq '8081|' <<<"$update_port_choices"; then
  echo "[Error] update-port choices should not include mappings for other domains." >&2
  printf '%s\n' "$update_port_choices" >&2
  exit 1
fi

add_port_choices="$(__arg_choices_nginx_port add-port)"
if ! grep -Fq '80|80' <<<"$add_port_choices" || ! grep -Fq '__MANUAL__|Enter manually...' <<<"$add_port_choices"; then
  echo "[Error] add-port listen choices should include common ports and manual entry." >&2
  printf '%s\n' "$add_port_choices" >&2
  exit 1
fi

suffix_choices="$(__arg_choices_port_suffix remove-cert)"
for expected in '443|443 (default)' '8443|8443 (HTTPS mapping)' '9443|9443' '9444|9444' '__MANUAL__|Enter manually...'; do
  if ! grep -Fq "$expected" <<<"$suffix_choices"; then
    echo "[Error] certificate suffix choices missing: $expected" >&2
    printf '%s\n' "$suffix_choices" >&2
    exit 1
  fi
done

cert_choice_output="$(__arg_choices_cert_choice add-cert)"
for expected in \
  'selfsigned|Generate self-signed certificate' \
  "letsencrypt|Generate Let's Encrypt certificate" \
  'upload|Upload existing fullchain.pem and privkey.pem'; do
  if ! grep -Fq "$expected" <<<"$cert_choice_output"; then
    echo "[Error] cert type choices missing: $expected" >&2
    printf '%s\n' "$cert_choice_output" >&2
    exit 1
  fi
done

cert_path_choices="$(__arg_choices_cert_path add-port)"
if ! grep -Fq 'none|Generate self-signed certificate' <<<"$cert_path_choices"; then
  echo "[Error] HTTPS cert choices should label none as self-signed generation." >&2
  printf '%s\n' "$cert_path_choices" >&2
  exit 1
fi

echo "interactive port/cert choice helper checks passed."
