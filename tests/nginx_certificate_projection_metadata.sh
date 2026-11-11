#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTION_CASE_RUNNER="${BASH_SOURCE[0]}"
CASES=(
  restrictive_private_key_metadata
  group_readable_private_key_metadata
  private_key_mode_change_rotates_generation
  failed_manifest_cannot_publish_partial_material
  permission_repair_rebuilds_derived_cache
)

# Keep each independently registered group within its native 90-second budget.
# shellcheck source=lib/nginx_certificate_projection_cases.sh
source "$ROOT_DIR/tests/lib/nginx_certificate_projection_cases.sh"
