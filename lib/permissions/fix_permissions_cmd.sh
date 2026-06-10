# shellcheck shell=bash
if ! declare -F __dockistrate_fix_permissions_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/permissions.sh first.
  # shellcheck source=./fix_permissions.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix_permissions.sh"
fi

function fix_permissions_cmd() {
  local target="${1:-$BASE_DIR}"

  case "$#" in
  0)
    fix_permissions "$target"
    ;;
  1)
    case "$target" in
    --certbot-darwin-user)
      fix_permissions_certbot_darwin_user
      ;;
    *)
      fix_permissions "$target"
      ;;
    esac
    ;;
  *)
    echo "[Error] Usage: fix-permissions [--certbot-darwin-user|target_dir]" >&2
    return 1
    ;;
  esac
}
