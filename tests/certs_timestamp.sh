#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lib/certs.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

cert_file="${TMP_DIR}/fullchain.pem"
: >"${cert_file}"
# Ensure a deterministic timestamp for GNU stat
TOUCH_TS="202401021234"
touch -t "${TOUCH_TS}" "${cert_file}"

linux_created=$(CERTS_UNAME="Linux" cert_created_timestamp "${cert_file}")
if [ "${linux_created}" != "2024-01-02" ]; then
  echo "Expected GNU timestamp 2024-01-02, got ${linux_created}" >&2
  exit 1
fi

# Stub stat to emulate BSD behaviour without requiring macOS utilities
real_stat=$(command -v stat)
stub_dir="${TMP_DIR}/stub"
mkdir -p "${stub_dir}"
cat <<'STUB' >"${stub_dir}/stat"
if [ "$1" = "-f" ]; then
  # Simulate BSD stat -f "%Sm" -t "%Y-%m-%d" output
  echo "2024-01-02"
  exit 0
fi
exec "$REAL_STAT" "$@"
STUB
chmod +x "${stub_dir}/stat"

darwin_created=$(REAL_STAT="${real_stat}" PATH="${stub_dir}:${PATH}" CERTS_UNAME="Darwin" \
  cert_created_timestamp "${cert_file}")
if [ "${darwin_created}" != "2024-01-02" ]; then
  echo "Expected Darwin timestamp 2024-01-02, got ${darwin_created}" >&2
  exit 1
fi

echo "All cert timestamp tests passed."
