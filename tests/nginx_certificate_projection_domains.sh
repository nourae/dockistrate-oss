#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTION_CASE_RUNNER="${BASH_SOURCE[0]}"
CASES=(
  domain_regular_material
  domain_ca_key_link
  domain_client_key_link
  domain_certificate_key_link
  domain_source_swap_link
  domain_parent_swap_link
)

# shellcheck source=lib/nginx_certificate_projection_cases.sh
source "$ROOT_DIR/tests/lib/nginx_certificate_projection_cases.sh"
