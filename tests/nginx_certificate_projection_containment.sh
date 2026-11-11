#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTION_CASE_RUNNER="${BASH_SOURCE[0]}"
CASES=(
  projection_root_symlink_rejected
  published_snapshot_tampering
  certificate_bytes_are_copied
  combined_mtls_pem_excludes_private_blocks
  hardlinked_private_key_rejected
  canonical_root_is_rejected_before_mutation
)

# Keep each independently registered group within its native 90-second budget.
# shellcheck source=lib/nginx_certificate_projection_cases.sh
source "$ROOT_DIR/tests/lib/nginx_certificate_projection_cases.sh"
