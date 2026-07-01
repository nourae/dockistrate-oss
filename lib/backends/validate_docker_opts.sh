# shellcheck shell=bash

function _docker_opts_normalize_profile() {
  local profile="${1:-backend}"
  case "$(printf '%s' "$profile" | tr '[:upper:]' '[:lower:]')" in
  nginx)
    printf '%s\n' "nginx"
    ;;
  *)
    printf '%s\n' "backend"
    ;;
  esac
}

function _docker_opts_conflict_owner_guidance() {
  local profile="${1:-backend}" option_key="${2:-}"
  case "${profile}:${option_key}" in
  backend:--name)
    printf '%s\n' "backend container naming (managed by add-backend/update-backend)"
    ;;
  backend:--network | backend:--net)
    printf '%s\n' "backend network selection (use add-backend/update-backend --network)"
    ;;
  backend:--rm)
    printf '%s\n' "backend lifecycle cleanup (use remove-backend)"
    ;;
  nginx:--name)
    printf '%s\n' "Nginx container naming (fixed to nginx-proxy)"
    ;;
  nginx:--network | nginx:--net)
    printf '%s\n' "Nginx network attachment (managed by start-nginx/update-nginx-config)"
    ;;
  nginx:--publish | nginx:-p | nginx:--publish-all | nginx:-P)
    printf '%s\n' "published listen ports (use add-port/remove-port/update-port)"
    ;;
  nginx:--volume | nginx:-v | nginx:--mount)
    printf '%s\n' "Nginx config/cert mounts (managed by Dockistrate)"
    ;;
  nginx:--entrypoint)
    printf '%s\n' "Nginx startup command and entrypoint (managed by Dockistrate)"
    ;;
  nginx:--rm)
    printf '%s\n' "Nginx lifecycle cleanup (use remove-nginx)"
    ;;
  *)
    printf '%s\n' "Dockistrate-managed container settings"
    ;;
  esac
}

function _docker_opts_conflicting_option_key() {
  local token="${1:-}" profile="${2:-backend}" option_key=""
  [ -n "$token" ] || return 1
  [[ "$token" == -* ]] || return 1
  [ "$token" = "--" ] && return 1

  option_key="$(_docker_opts_option_key "$token" 2>/dev/null || true)"
  [ -n "$option_key" ] || return 1

  case "$profile" in
  backend)
    case "$option_key" in
    --name | --network | --net | --rm)
      printf '%s\n' "$option_key"
      return 0
      ;;
    esac
    ;;
  nginx)
    case "$option_key" in
    --name | --network | --net | --rm | --publish | --publish-all | --volume | --mount | --entrypoint | -p | -P | -v)
      printf '%s\n' "$option_key"
      return 0
      ;;
    esac
    ;;
  esac

  return 1
}

function _docker_opts_option_key() {
  local token="${1:-}" option_key=""
  [ -n "$token" ] || return 1
  [[ "$token" == -* ]] || return 1
  [ "$token" = "--" ] && return 1

  option_key="$token"
  case "$option_key" in
  --*=*)
    option_key="${option_key%%=*}"
    ;;
  --*)
    ;;
  -?*)
    if [ "${#option_key}" -gt 2 ]; then
      option_key="${option_key:0:2}"
    fi
    ;;
  esac

  printf '%s\n' "$option_key"
}

function _docker_opts_option_disallows_separate_value() {
  local option_key="${1:-}"
  case "$option_key" in
  --detach | -d | --interactive | -i | --tty | -t | --publish-all | -P | --privileged | --init | --read-only | --sig-proxy | --oom-kill-disable | --no-healthcheck | --help)
    return 0
    ;;
  esac
  return 1
}

function _docker_opts_option_allows_separate_value() {
  local token="${1:-}" option_key=""
  [ -n "$token" ] || return 1
  [[ "$token" == -* ]] || return 1
  [ "$token" = "--" ] && return 1

  case "$token" in
  --*=*)
    return 1
    ;;
  esac

  if [[ "$token" == -?* ]] && [[ "$token" != --* ]] && [ "${#token}" -gt 2 ]; then
    # Short options with attached payload or bundled switches do not consume a separate token.
    return 1
  fi

  option_key="$(_docker_opts_option_key "$token" 2>/dev/null || true)"
  [ -n "$option_key" ] || return 1
  _docker_opts_option_disallows_separate_value "$option_key" && return 1
  return 0
}

function _docker_opts_positional_owner_guidance() {
  local profile="${1:-backend}"
  case "$profile" in
  nginx)
    printf '%s\n' "Nginx image/command and Dockistrate-managed proxy runtime arguments (ports, mounts, and network)"
    ;;
  *)
    printf '%s\n' "backend image/command and Dockistrate-managed backend runtime arguments (container name and network)"
    ;;
  esac
}

function _docker_opts_has_control_chars() {
  local token="${1:-}"
  printf '%s' "$token" | LC_ALL=C grep -q '[[:cntrl:]]'
}

function _docker_opts_reserved_nginx_label_key_from_spec() {
  local label_spec="${1:-}" label_key=""
  [ -n "$label_spec" ] || return 1
  label_key="${label_spec%%=*}"
  case "$label_key" in
  com.dockistrate.*)
    printf '%s\n' "$label_key"
    return 0
    ;;
  esac
  return 1
}

function _docker_opts_reserved_nginx_label_key_from_token() {
  local token="${1:-}" profile="${2:-backend}" option_key="" label_spec=""
  [ "$profile" = "nginx" ] || return 1

  option_key="$(_docker_opts_option_key "$token" 2>/dev/null || true)"
  case "$option_key" in
  --label)
    case "$token" in
    --label=*)
      label_spec="${token#--label=}"
      ;;
    esac
    ;;
  -l)
    if [ "$token" != "-l" ]; then
      label_spec="${token#-l}"
    fi
    ;;
  esac

  _docker_opts_reserved_nginx_label_key_from_spec "$label_spec"
}

function _docker_opts_reserved_nginx_label_key_from_value() {
  local value_token="${1:-}" profile="${2:-backend}" option_key="${3:-}"
  [ "$profile" = "nginx" ] || return 1
  case "$option_key" in
  --label | -l) ;;
  *)
    return 1
    ;;
  esac
  _docker_opts_reserved_nginx_label_key_from_spec "$value_token"
}

function _docker_opts_reserved_nginx_label_error() {
  local context="${1:-docker options}" label_key="${2:-}"
  echo "[Error] Failed to parse ${context}: docker label '${label_key}' is reserved for Dockistrate-managed proxy ownership." >&2
  return 1
}

function _docker_opts_quote_token() {
  local token="${1:-}"

  if [ -z "$token" ]; then
    printf "''"
    return 0
  fi

  # Keep common shell-safe tokens unquoted for readability.
  if [[ "$token" =~ ^[-A-Za-z0-9_./:=,@%+]+$ ]]; then
    printf '%s' "$token"
    return 0
  fi

  token="${token//\'/\'\\\'\'}"
  printf "'%s'" "$token"
}

function _docker_opts_rejected_token_for_display() {
  if declare -F operator_visibility_is_redacted >/dev/null 2>&1 &&
    operator_visibility_is_redacted; then
    printf '%s' "$OPERATOR_VISIBILITY_REDACTED_VALUE"
    return 0
  fi

  _docker_opts_quote_token "${1:-}"
}

function normalize_docker_opts_for_storage() {
  local raw_opts="${1:-}" context="${2:-docker options}" profile="${3:-backend}" reserved_label_policy="${4:-reject}"
  [ -z "$raw_opts" ] && return 0
  profile="$(_docker_opts_normalize_profile "$profile")"

  local docker_opts_lines=""
  if ! docker_opts_lines="$(_parse_docker_opts_to_lines "$raw_opts" "$context")"; then
    return 1
  fi

  if [ -z "$docker_opts_lines" ]; then
    return 0
  fi

  local canonical=""
  local token=""
  local blocked_option="" owner_guidance="" option_key="" reserved_label_key=""
  local positional_owner_guidance=""
  local allow_value_for_previous_option=false
  local pending_value_option=""
  local first=true
  while IFS= read -r token; do
    if _docker_opts_has_control_chars "$token"; then
      echo "[Error] Failed to parse ${context}: control characters are not allowed in docker options" >&2
      return 1
    fi

    if [ "$token" = "--" ]; then
      positional_owner_guidance="$(_docker_opts_positional_owner_guidance "$profile")"
      echo "[Error] Failed to parse ${context}: '--' is not allowed in docker options because it can override ${positional_owner_guidance}." >&2
      return 1
    fi

    if [[ "$token" == -* ]]; then
      if [ -n "$pending_value_option" ]; then
        echo "[Error] Failed to parse ${context}: docker option '${pending_value_option}' requires a value." >&2
        return 1
      fi

      option_key="$(_docker_opts_option_key "$token" 2>/dev/null || true)"
      blocked_option="$(_docker_opts_conflicting_option_key "$token" "$profile" 2>/dev/null || true)"
      if [ -n "$blocked_option" ]; then
        owner_guidance="$(_docker_opts_conflict_owner_guidance "$profile" "$blocked_option")"
        echo "[Error] Failed to parse ${context}: docker option '${blocked_option}' conflicts with ${owner_guidance}." >&2
        return 1
      fi

      reserved_label_key="$(_docker_opts_reserved_nginx_label_key_from_token "$token" "$profile" 2>/dev/null || true)"
      if [ -n "$reserved_label_key" ] && [ "$reserved_label_policy" != "allow" ]; then
        _docker_opts_reserved_nginx_label_error "$context" "$reserved_label_key"
        return 1
      fi

      if _docker_opts_option_allows_separate_value "$token"; then
        allow_value_for_previous_option=true
        pending_value_option="${option_key:-$token}"
      else
        allow_value_for_previous_option=false
        pending_value_option=""
      fi
    else
      if [ "$allow_value_for_previous_option" = true ]; then
        reserved_label_key="$(_docker_opts_reserved_nginx_label_key_from_value "$token" "$profile" "$pending_value_option" 2>/dev/null || true)"
        if [ -n "$reserved_label_key" ] && [ "$reserved_label_policy" != "allow" ]; then
          _docker_opts_reserved_nginx_label_error "$context" "$reserved_label_key"
          return 1
        fi
        allow_value_for_previous_option=false
        pending_value_option=""
      else
        positional_owner_guidance="$(_docker_opts_positional_owner_guidance "$profile")"
        echo "[Error] Failed to parse ${context}: positional token $(_docker_opts_rejected_token_for_display "$token") is not allowed in docker options because it can override ${positional_owner_guidance}." >&2
        return 1
      fi
    fi

    if [ "$first" = true ]; then
      first=false
    else
      canonical+=" "
    fi
    canonical+="$(_docker_opts_quote_token "$token")"
  done <<<"$docker_opts_lines"

  if [ -n "$pending_value_option" ]; then
    echo "[Error] Failed to parse ${context}: docker option '${pending_value_option}' requires a value." >&2
    return 1
  fi

  printf '%s' "$canonical"
}
