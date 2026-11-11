#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTION_CASE_RUNNER="${BASH_SOURCE[0]}"
CASES=(
  missing_manifest_has_no_rollback_authority
  changed_nested_type_has_no_rollback_authority
  capture_stat_failure_is_operational
  capture_digest_failure_is_operational
)

# shellcheck source=lib/nginx_certificate_projection_cases.sh
source "$ROOT_DIR/tests/lib/nginx_certificate_projection_cases.sh"
