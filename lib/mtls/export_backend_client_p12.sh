# shellcheck shell=bash

function export_backend_client_p12() {
  local domain="${1:-}" client="${2:-}" # input-validation-audit: ignore
  if [ -z "$domain" ] || [ -z "$client" ]; then
    echo "[Usage] export-backend-client-p12 <domain> <client_name> [--password-file path|--password-env var|--password-stdin]"
    exit 1
  fi

  # Domain is validated centrally before any mTLS path resolution or file access.
  _mtls_normalize_valid_domain domain "$domain" || exit 1
  if ! is_valid_client_name "$client"; then
    echo "[Error] Invalid client name: '$client'. Use only alphanumeric characters, hyphens, underscores, and dots." >&2
    exit 1
  fi

  shift 2 || true

  local password_mode="" password_file="" password_env=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --password-file)
      [ -n "${2:-}" ] || {
        echo "[Error] --password-file requires a path" >&2
        exit 1
      }
      [ -z "$password_mode" ] || {
        echo "[Error] Specify only one password source" >&2
        exit 1
      }
      password_mode="file"
      password_file="$2"
      shift 2
      ;;
    --password-env)
      [ -n "${2:-}" ] || {
        echo "[Error] --password-env requires a variable name" >&2
        exit 1
      }
      if ! require_valid_var_name "$2" >/dev/null 2>&1; then
        echo "[Error] Invalid environment variable name: '$2'" >&2
        exit 1
      fi
      [ -z "$password_mode" ] || {
        echo "[Error] Specify only one password source" >&2
        exit 1
      }
      password_mode="env"
      password_env="$2"
      shift 2
      ;;
    --password-stdin)
      [ -z "$password_mode" ] || {
        echo "[Error] Specify only one password source" >&2
        exit 1
      }
      password_mode="stdin"
      shift
      ;;
    *)
      echo "[Usage] export-backend-client-p12 <domain> <client_name> [--password-file path|--password-env var|--password-stdin]"
      exit 1
      ;;
    esac
  done

  local mtls_dir=""
  if ! _resolve_backend_mtls_dir mtls_dir "$domain"; then
    exit 1
  fi
  _mtls_validate_authority_state "$mtls_dir" || return 1
  if ! _mtls_require_client_cert_files "$mtls_dir" "$client"; then
    exit 1
  fi
  local p12="${mtls_dir}/${client}.p12"

  local xtrace_state=""
  xtrace_disable xtrace_state

  local password="" pass1="" pass2=""
  local password_file_line_terminated="false" password_file_has_extra="false" password_file_extra=""
  local password_stdin_read="false" password_stdin_line_terminated="false"
  local password_stdin_has_extra="false" password_stdin_extra=""
  case "$password_mode" in
  file)
    if [ ! -f "$password_file" ]; then
      echo "[Error] Password file not found: $password_file" >&2
      exit 1
    fi
    if ! {
      if IFS= read -r password; then
        password_file_line_terminated="true"
      fi
      if IFS= read -r password_file_extra || [ -n "$password_file_extra" ]; then
        password_file_has_extra="true"
      fi
    } <"$password_file"; then
      echo "[Error] Unable to read password file: $password_file" >&2
      exit 1
    fi
    if [ "$password_file_has_extra" = "true" ]; then
      echo "[Error] Password file must contain exactly one line (an optional final LF or CRLF is allowed)" >&2
      exit 1
    fi
    if [ "$password_file_line_terminated" = "true" ]; then
      case "$password" in
      *$'\r') password="${password%$'\r'}" ;;
      esac
    fi
    ;;
  env)
    if ! require_valid_var_name "$password_env" >/dev/null 2>&1; then
      echo "[Error] Invalid environment variable name: '$password_env'" >&2
      exit 1
    fi
    if [ -z "${!password_env:-}" ]; then
      echo "[Error] Environment variable '$password_env' is empty" >&2
      exit 1
    fi
    password="${!password_env}"
    ;;
  stdin)
    if IFS= read -r password; then
      password_stdin_read="true"
      password_stdin_line_terminated="true"
    elif [ -n "$password" ]; then
      password_stdin_read="true"
    fi
    if [ "$password_stdin_read" != "true" ]; then
      echo "[Error] Failed to read password from stdin" >&2
      exit 1
    fi
    if IFS= read -r password_stdin_extra || [ -n "$password_stdin_extra" ]; then
      password_stdin_has_extra="true"
    fi
    if [ "$password_stdin_has_extra" = "true" ]; then
      echo "[Error] Password stdin must contain exactly one line (an optional final LF or CRLF is allowed)" >&2
      exit 1
    fi
    if [ "$password_stdin_line_terminated" = "true" ]; then
      case "$password" in
      *$'\r') password="${password%$'\r'}" ;;
      esac
    fi
    ;;
  "")
    while true; do
      read -rsp "Enter export password: " pass1
      echo
      read -rsp "Confirm export password: " pass2
      echo
      [ "$pass1" = "$pass2" ] && {
        password="$pass1"
        break
      }
      echo "[Error] Passwords do not match. Try again." >&2
    done
    ;;
  esac

  case "$password" in
  *$'\r'* | *$'\n'*)
    echo "[Error] Export password must be a single line and cannot contain CR or LF characters" >&2
    exit 1
    ;;
  esac

  if [ -z "$password" ]; then
    echo "[Error] Export password cannot be empty" >&2
    exit 1
  fi

  if ! _mtls_write_client_p12 "$mtls_dir" "$client" "$password"; then
    unset password pass1 pass2
    exit 1
  fi
  _mtls_chmod_file "$mtls_dir" "${client}.p12" 600 || {
    unset password pass1 pass2
    exit 1
  }

  xtrace_restore "$xtrace_state"
  unset password pass1 pass2
  echo "[Info] Generated PKCS#12 file ${p12}"
}
