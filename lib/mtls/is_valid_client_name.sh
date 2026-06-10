# shellcheck shell=bash

# Validate mTLS client certificate names.
# Client names are used in file paths and OpenSSL subject fields, so we restrict
# them to safe characters: alphanumeric, hyphens, underscores, and dots.
# Path components like '..' are explicitly rejected to prevent path traversal.
function is_valid_client_name() {
  local name="${1:-}"

  # Must not be empty
  [ -n "$name" ] || return 1

  # Must only contain safe characters (alphanumeric, hyphen, underscore, dot)
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

  # Reject path traversal attempts
  [[ "$name" == *".."* ]] && return 1

  # Reject names starting or ending with dots/hyphens
  [[ "$name" =~ ^[.] || "$name" =~ ^[-] ]] && return 1
  [[ "$name" =~ [.]$ || "$name" =~ [-]$ ]] && return 1

  # Reject names that are too long (max 64 chars, reasonable for CN field)
  [ "${#name}" -le 64 ] || return 1

  return 0
}
