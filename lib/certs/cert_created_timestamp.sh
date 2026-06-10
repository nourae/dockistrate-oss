# shellcheck shell=bash

# Compute the created timestamp for a certificate in a cross-platform way
function cert_created_timestamp() {
  local cert_path="${1:-}"
  [ -n "$cert_path" ] || {
    echo "Unknown"
    return 0
  }
  [ -f "$cert_path" ] || {
    echo "Unknown"
    return 0
  }

  local os_name
  if [ -n "${CERTS_UNAME:-}" ]; then
    os_name="$CERTS_UNAME"
  else
    os_name="$(uname -s 2>/dev/null || echo Unknown)"
  fi

  local created=""
  case "$os_name" in
  Darwin)
    if created=$(stat -f "%Sm" -t "%Y-%m-%d" "$cert_path" 2>/dev/null); then
      echo "$created"
      return 0
    fi
    ;;
  *)
    if created=$(stat -c %y "$cert_path" 2>/dev/null); then
      created="${created%% *}"
      if [ -n "$created" ]; then
        echo "$created"
        return 0
      fi
    fi
    if created=$(stat -f "%Sm" -t "%Y-%m-%d" "$cert_path" 2>/dev/null); then
      echo "$created"
      return 0
    fi
    ;;
  esac

  echo "Unknown"
  return 0
}
