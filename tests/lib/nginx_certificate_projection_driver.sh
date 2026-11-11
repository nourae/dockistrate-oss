#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"
# shellcheck source=../../lib/nginx.sh
source "$ROOT_DIR/lib/nginx.sh"
_nginx_certificate_projection_helper "$@"
