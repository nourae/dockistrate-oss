# shellcheck shell=bash
function _effective_user() {
  if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && id -u "$SUDO_USER" >/dev/null 2>&1; then
    echo "$SUDO_USER"
  else
    id -un 2>/dev/null || echo "$USER"
  fi
}
