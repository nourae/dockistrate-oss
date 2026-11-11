#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTION_CASE_RUNNER="${BASH_SOURCE[0]}"
CASES=(
  restricted_modes_under_022
  restricted_modes_under_077
  letsencrypt_archive_symlinks
  external_server_certificate_symlink
  external_server_key_symlink
  external_mtls_certificate_symlink
  external_mtls_crl_symlink
  special_file_rejected
  source_rewrite_during_copy_is_rejected
)

# Keep each independently registered group within its native 90-second budget.
# shellcheck source=lib/nginx_certificate_projection_cases.sh
source "$ROOT_DIR/tests/lib/nginx_certificate_projection_cases.sh"
