#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTION_CASE_RUNNER="${BASH_SOURCE[0]}"
CASES=(
  atomic_crl_rotation
  atomic_ca_rotation
  atomic_server_certificate_rotation
  server_private_key_rotation
  removed_mapping_removes_public_material
)

# Keep each independently registered group within its native 90-second budget.
# shellcheck source=lib/nginx_certificate_projection_cases.sh
source "$ROOT_DIR/tests/lib/nginx_certificate_projection_cases.sh"
