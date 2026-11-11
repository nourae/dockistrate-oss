#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$BASH" "$ROOT_DIR/tests/lib/backend_failed_start_fixture.sh" add "$@"
