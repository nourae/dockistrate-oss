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
  if ! _mtls_require_client_cert_files "$mtls_dir" "$client"; then
    exit 1
  fi
  local p12="${mtls_dir}/${client}.p12"

  local xtrace_state=""
  xtrace_disable xtrace_state

  local password="" pass1 pass2
  case "$password_mode" in
  file)
    if [ ! -f "$password_file" ]; then
      echo "[Error] Password file not found: $password_file" >&2
      exit 1
    fi
    password="$(head -n1 "$password_file" | tr -d '\r\n')"
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
    if ! IFS= read -r password; then
      echo "[Error] Failed to read password from stdin" >&2
      exit 1
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
