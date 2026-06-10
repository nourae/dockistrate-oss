#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"
# shellcheck source=../lib/cli/arg_choices_misc.sh
source "$ROOT_DIR/lib/cli/arg_choices_misc.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_cert_path_date.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

CERTS_DIR="$tmp_dir/certs"
NGINX_HTTP_CONF_DIR="$tmp_dir/nginx"
BACKEND_PORTS_FILE="$tmp_dir/backend_ports.csv"
stub_dir="$tmp_dir/bin"
mkdir -p "$CERTS_DIR/letsencrypt/live/bsdcert" "$NGINX_HTTP_CONF_DIR" "$stub_dir"
printf '%s\n' 'this-is-not-a-certificate' >"$CERTS_DIR/letsencrypt/live/bsdcert/fullchain.pem"

real_date="$(command -v date)"
real_stat="$(command -v stat)"
export REAL_DATE="$real_date"
export REAL_STAT="$real_stat"

cat >"$stub_dir/date" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-r" ]; then
  exit 1
fi
exec "$REAL_DATE" "$@"
STUB
chmod +x "$stub_dir/date"

cat >"$stub_dir/stat" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-c" ]; then
  exit 1
fi
if [ "${1:-}" = "-f" ] && [ "${2:-}" = "%Sm" ] && [ "${3:-}" = "-t" ] && [ "${4:-}" = "%Y-%m-%d" ]; then
  printf '%s\n' "2024-01-02"
  exit 0
fi
exec "$REAL_STAT" "$@"
STUB
chmod +x "$stub_dir/stat"

choices="$(PATH="$stub_dir:$PATH" __arg_choices_cert_path "add-port")"

if ! grep -Fq "letsencrypt/live/bsdcert|" <<<"$choices"; then
  echo "[Error] Expected certificate entry to remain listable." >&2
  echo "$choices" >&2
  exit 1
fi

if ! grep -Fq " | 2024-01-02 | " <<<"$choices"; then
  echo "[Error] Expected BSD stat fallback to populate created date." >&2
  echo "$choices" >&2
  exit 1
fi

if grep -Fq " | Unknown | " <<<"$choices"; then
  echo "[Error] Created date should not fall back to Unknown when BSD stat succeeds." >&2
  echo "$choices" >&2
  exit 1
fi

echo "cert path created-date portability checks passed."
