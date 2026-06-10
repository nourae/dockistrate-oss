# shellcheck shell=bash

function _notify_cert_warning() {
  local message="${1:-}"
  local email_target="${2:-}"

  echo "[Warn] ${message}"
  log_msg "$message"

  if [ -n "$email_target" ]; then
    if command -v mail >/dev/null 2>&1; then
      echo "$message" | mail -s "Dockistrate certificate warning" "$email_target" 2>/dev/null ||
        log_msg "Failed to send certificate warning email to ${email_target}"
    elif command -v sendmail >/dev/null 2>&1; then
      {
        printf "Subject: Dockistrate certificate warning\n"
        printf "To: %s\n" "$email_target"
        printf "\n%s\n" "$message"
      } | sendmail -t 2>/dev/null ||
        log_msg "Failed to send certificate warning email to ${email_target}"
    else
      log_msg "Email notification requested but 'mail' or 'sendmail' is not available"
    fi
  fi
}
