#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTION_CASE_RUNNER="${BASH_SOURCE[0]}"
PROJECTION_TEST_LABEL="Nginx certificate rollback"
PROJECTION_CASE_FUNCTION=test_projection_rollback
CASES=(
  reload_only_root_commit_failure
)

# Keep every runtime assertion under the unchanged per-script deadline.
# shellcheck source=lib/nginx_certificate_projection_runtime_cases.sh
source "$ROOT_DIR/tests/lib/nginx_certificate_projection_runtime_cases.sh"
