#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"
# shellcheck source=../lib/cli/arg_choices_misc.sh
source "$ROOT_DIR/lib/cli/arg_choices_misc.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_add_backend_cert_choices.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

CERTS_DIR="$tmp_dir/certs"
NGINX_HTTP_CONF_DIR="$tmp_dir/nginx"
BACKEND_PORTS_FILE="$tmp_dir/backend_ports.csv"
mkdir -p "$CERTS_DIR" "$NGINX_HTTP_CONF_DIR"

choices="$(__arg_choices_cert_path "add-backend")"
if ! grep -Fq "selfsigned|Generate self-signed certificate" <<<"$choices"; then
  echo "[Error] add-backend cert choices should offer self-signed generation." >&2
  echo "$choices" >&2
  exit 1
fi
if ! grep -Fq "letsencrypt|Generate Let's Encrypt certificate" <<<"$choices"; then
  echo "[Error] add-backend cert choices should offer Let's Encrypt generation." >&2
  echo "$choices" >&2
  exit 1
fi
if grep -Fq "none|Generate cert" <<<"$choices"; then
  echo "[Error] add-backend cert choices should not use the ambiguous legacy Generate cert label." >&2
  echo "$choices" >&2
  exit 1
fi

port_choices="$(__arg_choices_cert_path "add-port")"
if ! grep -Fq "none|Generate self-signed certificate" <<<"$port_choices"; then
  echo "[Error] add-port cert choices should label the none fallback as self-signed generation." >&2
  echo "$port_choices" >&2
  exit 1
fi

echo "[tests] interactive_add_backend_cert_choices.sh: PASS"
