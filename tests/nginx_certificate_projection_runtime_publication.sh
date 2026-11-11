#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTION_CASE_RUNNER="${BASH_SOURCE[0]}"
PROJECTION_TEST_LABEL="Nginx certificate runtime"
PROJECTION_CASE_FUNCTION=test_projection_runtime
CASES=(
  invalid_publication_preserves_runtime
  source_rotation_between_prepare_and_launch
)

# Keep every runtime assertion under the unchanged per-script deadline.
# shellcheck source=lib/nginx_certificate_projection_runtime_cases.sh
source "$ROOT_DIR/tests/lib/nginx_certificate_projection_runtime_cases.sh"
