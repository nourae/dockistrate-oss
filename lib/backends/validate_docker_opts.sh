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

  _docker_opts_short_bundle_conflicting_option_key "$token" "$profile"
}

function _docker_opts_conflicting_short_key_for_profile() {
  local profile="${1:-backend}" option_key="${2:-}"

  case "${profile}:${option_key}" in
  nginx:-p | nginx:-P | nginx:-v)
    printf '%s\n' "$option_key"
    return 0
    ;;
  esac

  return 1
}

function _docker_opts_short_bundle_conflicting_option_key() {
  local token="${1:-}" profile="${2:-backend}" option_key=""
  local i=1 token_length=0

  [[ "$token" == -?* ]] || return 1
  [[ "$token" != --* ]] || return 1
  token_length="${#token}"
  [ "$token_length" -gt 2 ] || return 1

  while [ "$i" -lt "$token_length" ]; do
    option_key="-${token:i:1}"
    if _docker_opts_conflicting_short_key_for_profile "$profile" "$option_key"; then
      return 0
    fi

    # Docker permits boolean shorthand flags to be bundled (for example,
    # -it). Once a value-taking shorthand is reached, the rest of the token is
    # its attached value and must not be inspected as more option keys.
    [ "$(_docker_opts_option_arity "$option_key")" = "boolean" ] || return 1
    [ "${token:$((i + 1)):1}" != "=" ] || return 1
    i=$((i + 1))
  done

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

function _docker_opts_option_arity() {
  local option_key="${1:-}"
  # Docker CLI run.go/opts.go at 52a2671034814f1ec6145aa8238c5fd4f92d5ee7.
  # Include hidden aliases and platform-specific flags. Unknown flags must not
  # be guessed to take a value: Docker may treat that value as its image.
  case "$option_key" in
  --detach | --disable-content-trust | --help | --init | --interactive | \
    --no-healthcheck | --oom-kill-disable | --privileged | --publish-all | \
    --quiet | --read-only | --rm | --sig-proxy | --tty | --use-api-socket | \
    -P | -d | -i | -q | -t)
    printf '%s\n' "boolean"
    ;;
  --add-host | --annotation | --attach | --blkio-weight | --blkio-weight-device | \
    --cap-add | --cap-drop | --cgroup-parent | --cgroupns | --cidfile | \
    --cpu-count | --cpu-percent | --cpu-period | --cpu-quota | --cpu-rt-period | \
    --cpu-rt-runtime | --cpu-shares | --cpus | --cpuset-cpus | --cpuset-mems | \
    --detach-keys | --device | --device-cgroup-rule | --device-read-bps | \
    --device-read-iops | --device-write-bps | --device-write-iops | --dns | \
    --dns-opt | --dns-option | --dns-search | --domainname | --entrypoint | \
    --env | --env-file | --expose | --gpus | --group-add | --health-cmd | \
    --health-interval | --health-retries | --health-start-interval | \
    --health-start-period | --health-timeout | --hostname | --io-maxbandwidth | \
    --io-maxiops | --ip | --ip6 | --ipc | --isolation | --kernel-memory | \
    --label | --label-file | --link | --link-local-ip | --log-driver | --log-opt | \
    --mac-address | --memory | --memory-reservation | --memory-swap | \
    --memory-swappiness | --mount | --name | --net | --net-alias | --network | \
    --network-alias | --oom-score-adj | --pid | --pids-limit | --platform | \
    --publish | --pull | --restart | --runtime | --security-opt | --shm-size | \
    --stop-signal | --stop-timeout | --storage-opt | --sysctl | --tmpfs | \
    --ulimit | --umask | --user | --userns | --uts | --volume | --volume-driver | \
    --volumes-from | --workdir | -a | -c | -e | -h | -l | -m | -p | -u | -v | -w)
    printf '%s\n' "value"
    ;;
  *)
    printf '%s\n' "unknown"
    ;;
  esac
}

function _docker_opts_validate_option_token() {
  local token="${1:-}" context="${2:-docker options}" option_key=""
  local i=1 token_length="${#token}"
  case "$token" in
  --*)
    option_key="${token%%=*}"
    if [ "$(_docker_opts_option_arity "$option_key")" != "unknown" ]; then
      return 0
    fi
    # Explicit values are unambiguous for future boolean and value-taking
    # options alike. Docker still validates the option and its value.
    case "$token" in --?*=*) return 0 ;; esac
    echo "[Error] Failed to parse ${context}: unrecognized docker option $(_docker_opts_rejected_token_for_display "$option_key") requires explicit --option=value syntax (use =true or =false for a boolean)." >&2
    return 1
    ;;
  esac

  while [ "$i" -lt "$token_length" ]; do
    option_key="-${token:i:1}"
    case "$(_docker_opts_option_arity "$option_key")" in
    boolean)
      [ "${token:$((i + 1)):1}" != "=" ] || return 0
      ;;
    value)
      # The rest of the token belongs to this option, not to more flags.
      return 0
      ;;
    *)
      echo "[Error] Failed to parse ${context}: unrecognized docker shorthand $(_docker_opts_rejected_token_for_display "$option_key"); use the long --option=value form." >&2
      return 1
      ;;
    esac
    i=$((i + 1))
  done
  return 0
}

function _docker_opts_short_bundle_attached_value_for_key() {
  local token="${1:-}" wanted_key="${2:-}" option_key="" value=""
  local i=1 token_length=0

  [[ "$token" == -?* ]] || return 1
  [[ "$token" != --* ]] || return 1
  token_length="${#token}"
  [ "$token_length" -gt 2 ] || return 1

  while [ "$i" -lt "$token_length" ]; do
    option_key="-${token:i:1}"
    if [ "$option_key" = "$wanted_key" ]; then
      value="${token:$((i + 1))}"
      value="${value#=}"
      [ -n "$value" ] || return 1
      printf '%s\n' "$value"
      return 0
    fi

    [ "$(_docker_opts_option_arity "$option_key")" = "boolean" ] || return 1
    [ "${token:$((i + 1)):1}" != "=" ] || return 1
    i=$((i + 1))
  done

  return 1
}

function _docker_opts_short_bundle_terminal_value_key() {
  local token="${1:-}" option_key=""
  local i=1 token_length=0

  [[ "$token" == -?* ]] || return 1
  [[ "$token" != --* ]] || return 1
  token_length="${#token}"
  [ "$token_length" -gt 2 ] || return 1

  while [ "$i" -lt "$token_length" ]; do
    option_key="-${token:i:1}"
    case "$(_docker_opts_option_arity "$option_key")" in
    value)
      if [ "$i" -eq $((token_length - 1)) ]; then
        printf '%s\n' "$option_key"
        return 0
      fi
      return 1
      ;;
    boolean)
      [ "${token:$((i + 1)):1}" != "=" ] || return 1
      ;;
    *) return 1 ;;
    esac
    i=$((i + 1))
  done

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
    # A value-taking option at the end of a boolean shorthand bundle may take
    # the following token (for example, -il app=demo). Attached payloads and
    # all-boolean bundles do not consume a separate token.
    _docker_opts_short_bundle_terminal_value_key "$token" >/dev/null 2>&1
    return $?
  fi

  option_key="$(_docker_opts_option_key "$token" 2>/dev/null || true)"
  [ -n "$option_key" ] || return 1
  [ "$(_docker_opts_option_arity "$option_key")" = "value" ]
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
  local label_spec="${1:-}" profile="${2:-nginx}" label_key=""
  [ -n "$label_spec" ] || return 1
  label_key="${label_spec%%=*}"
  case "$profile:$label_key" in
  nginx:com.dockistrate.* | backend:com.dockistrate.managed | backend:com.dockistrate.role | \
    backend:com.dockistrate.state-dir | backend:com.dockistrate.backend-domain | backend:com.dockistrate.backend-launch)
    printf '%s\n' "$label_key"
    return 0
    ;;
  esac
  return 1
}

function _docker_opts_reserved_nginx_label_key_from_token() {
  local token="${1:-}" profile="${2:-backend}" label_spec=""
  case "$profile" in nginx | backend) ;; *) return 1 ;; esac

  case "$token" in
  --label=*)
    label_spec="${token#--label=}"
    ;;
  -?*)
    label_spec="$(_docker_opts_short_bundle_attached_value_for_key "$token" "-l" 2>/dev/null || true)"
    ;;
  esac

  _docker_opts_reserved_nginx_label_key_from_spec "$label_spec" "$profile"
}

function _docker_opts_reserved_nginx_label_key_from_value() {
  local value_token="${1:-}" profile="${2:-backend}" option_key="${3:-}"
  case "$profile" in nginx | backend) ;; *) return 1 ;; esac
  case "$option_key" in
  --label | -l) ;;
  *)
    return 1
    ;;
  esac
  _docker_opts_reserved_nginx_label_key_from_spec "$value_token" "$profile"
}

function _docker_opts_reserved_nginx_label_error() {
  local context="${1:-docker options}" label_key="${2:-}" profile="${3:-nginx}" role=proxy
  [ "$profile" != backend ] || role=backend
  echo "[Error] Failed to parse ${context}: docker label '${label_key}' is reserved for Dockistrate-managed ${role} ownership." >&2
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
  if ! _parse_docker_opts_capture_lines docker_opts_lines "$raw_opts" "$context"; then
    return 1
  fi

  if [ -z "$docker_opts_lines" ]; then
    return 0
  fi

  local canonical=""
  local token="" bundled_value_option=""
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

    if [[ "$token" == -?* ]]; then
      if [ -n "$pending_value_option" ]; then
        echo "[Error] Failed to parse ${context}: docker option '${pending_value_option}' requires a value." >&2
        return 1
      fi

      _docker_opts_validate_option_token "$token" "$context" || return 1
      option_key="$(_docker_opts_option_key "$token" 2>/dev/null || true)"
      blocked_option="$(_docker_opts_conflicting_option_key "$token" "$profile" 2>/dev/null || true)"
      if [ -n "$blocked_option" ]; then
        owner_guidance="$(_docker_opts_conflict_owner_guidance "$profile" "$blocked_option")"
        echo "[Error] Failed to parse ${context}: docker option '${blocked_option}' conflicts with ${owner_guidance}." >&2
        return 1
      fi

      reserved_label_key="$(_docker_opts_reserved_nginx_label_key_from_token "$token" "$profile" 2>/dev/null || true)"
      if [ -n "$reserved_label_key" ] && [ "$reserved_label_policy" != "allow" ]; then
        _docker_opts_reserved_nginx_label_error "$context" "$reserved_label_key" "$profile"
        return 1
      fi

      if _docker_opts_option_allows_separate_value "$token"; then
        allow_value_for_previous_option=true
        bundled_value_option="$(_docker_opts_short_bundle_terminal_value_key "$token" 2>/dev/null || true)"
        pending_value_option="${bundled_value_option:-${option_key:-$token}}"
      else
        allow_value_for_previous_option=false
        pending_value_option=""
      fi
    else
      if [ "$allow_value_for_previous_option" = true ]; then
        reserved_label_key="$(_docker_opts_reserved_nginx_label_key_from_value "$token" "$profile" "$pending_value_option" 2>/dev/null || true)"
        if [ -n "$reserved_label_key" ] && [ "$reserved_label_policy" != "allow" ]; then
          _docker_opts_reserved_nginx_label_error "$context" "$reserved_label_key" "$profile"
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
  done < <(printf '%s' "$docker_opts_lines")

  if [ -n "$pending_value_option" ]; then
    echo "[Error] Failed to parse ${context}: docker option '${pending_value_option}' requires a value." >&2
    return 1
  fi

  printf '%s' "$canonical"
}
