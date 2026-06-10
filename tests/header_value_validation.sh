#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"

if ! is_valid_header_value "ok-value"; then
  echo "[Error] Expected valid header value to pass" >&2
  exit 1
fi

if is_valid_header_value $'bad\nvalue'; then
  echo "[Error] Expected newline to be rejected" >&2
  exit 1
fi

if is_valid_header_value $'bad\rvalue'; then
  echo "[Error] Expected carriage return to be rejected" >&2
  exit 1
fi

if is_valid_header_value $'bad\tvalue'; then
  echo "[Error] Expected tab to be rejected" >&2
  exit 1
fi

echo "Header value validation checks passed."
