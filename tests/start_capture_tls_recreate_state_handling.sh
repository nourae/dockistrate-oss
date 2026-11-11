#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The shared fixture exercises real TLS state, snapshot restoration, and runtime
# recovery. Status 2 preserves enabled state only if recovery cannot disable it.
CAPTURE_TLS_TEST_GROUP=recreate "$BASH" "$ROOT_DIR/tests/start_capture_tls_launch_rollback.sh"
