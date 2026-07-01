#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"
# shellcheck source=../lib/cli/arg_choices_misc.sh
source "$ROOT_DIR/lib/cli/arg_choices_misc.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_cert_path_choices.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

CERTS_DIR="$tmp_dir/certs"
NGINX_HTTP_CONF_DIR="$tmp_dir/nginx"
BACKEND_PORTS_FILE="$tmp_dir/backend_ports.csv"
mkdir -p "$CERTS_DIR/letsencrypt/live/badcert" "$NGINX_HTTP_CONF_DIR"
printf '%s\n' 'this-is-not-a-certificate' >"$CERTS_DIR/letsencrypt/live/badcert/fullchain.pem"

if choices="$(__arg_choices_cert_path "add-port")"; then
  :
else
  echo "[Error] __arg_choices_cert_path failed for malformed certificate input." >&2
  exit 1
fi

if ! grep -Fq "letsencrypt/live/badcert|" <<<"$choices"; then
  echo "[Error] Expected malformed certificate entry to remain listable." >&2
  echo "$choices" >&2
  exit 1
fi

if ! grep -Fq "none|Generate self-signed certificate" <<<"$choices"; then
  echo "[Error] Expected self-signed generation fallback option in cert choices." >&2
  echo "$choices" >&2
  exit 1
fi

echo "cert path malformed certificate guard passed."
