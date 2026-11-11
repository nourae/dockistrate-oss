#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTION_CASE_RUNNER="${BASH_SOURCE[0]}"
CASES=(
  restored_cache_metadata_does_not_block_retirement
  newline_path_and_mount_identity
  docker_mock_preserves_complete_mount_inventory
  current_readonly_projection_mount
  legacy_broad_mount_requires_recreation
  writable_projection_mount_rejected
)

# Keep each independently registered group within its native 90-second budget.
# shellcheck source=lib/nginx_certificate_projection_cases.sh
source "$ROOT_DIR/tests/lib/nginx_certificate_projection_cases.sh"
