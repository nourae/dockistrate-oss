# shellcheck shell=bash
function ensure_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "[Error] Please run this as root or via sudo." >&2
    exit 1
  fi
}
