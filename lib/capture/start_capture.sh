# shellcheck shell=bash

function _capture_collapse_absolute_path() {
  local __var="$1" path_in="${2:-}"
  require_valid_var_name "$__var" || return 1
  [ -n "$path_in" ] || return 1
  case "$path_in" in
  /*) ;;
  *)
    return 1
    ;;
  esac

  # Split on path separators, not lines: a newline can be part of a filename.
  local remaining="${path_in#/}"
  local -a stack=()
  local segment=""
  while [ -n "$remaining" ]; do
    segment="${remaining%%/*}"
    if [ "$remaining" = "$segment" ]; then
      remaining=""
    else
      remaining="${remaining#*/}"
    fi
    case "$segment" in
    "" | .) ;;
    ..)
      if [ ${#stack[@]} -gt 0 ]; then
        unset "stack[${#stack[@]}-1]"
      fi
      ;;
    *)
      stack+=("$segment")
      ;;
    esac
  done

  local collapsed="/"
  if [ ${#stack[@]} -gt 0 ]; then
    collapsed="/${stack[0]}"
    local i=1
    while [ $i -lt ${#stack[@]} ]; do
      collapsed="${collapsed}/${stack[$i]}"
      i=$((i + 1))
    done
  fi

  printf -v "$__var" '%s' "$collapsed"
}

function _capture_resolve_existing_path() {
  local __var="$1" path_in="${2:-}"
  require_valid_var_name "$__var" || return 1
  [ -e "$path_in" ] || return 1

  local resolved=""
  if [ -d "$path_in" ]; then
    resolved="$(cd -- "$path_in" >/dev/null 2>&1 && pwd -P && printf '.')" || return 1
    resolved="${resolved%.}"
    resolved="${resolved%$'\n'}"
  else
    local resolved_dir="" parent_path="${path_in%/*}" leaf_name="${path_in##*/}"
    if [ "$parent_path" = "$path_in" ]; then
      parent_path="."
    elif [ -z "$parent_path" ]; then
      parent_path="/"
    fi
    resolved_dir="$(cd -- "$parent_path" >/dev/null 2>&1 && pwd -P && printf '.')" || return 1
    resolved_dir="${resolved_dir%.}"
    resolved_dir="${resolved_dir%$'\n'}"
    resolved="${resolved_dir%/}/${leaf_name}"
  fi

  _capture_collapse_absolute_path resolved "$resolved" || return 1
  printf -v "$__var" '%s' "$resolved"
}

function _capture_resolve_output_path() {
  local __var="$1" path_in="${2:-}"
  require_valid_var_name "$__var" || return 1
  [ -n "$path_in" ] || return 1

  local absolute_path="$path_in"
  if [[ "$absolute_path" != /* ]]; then
    absolute_path="${BASE_DIR%/}/${absolute_path#./}"
  fi

  local search_path="$absolute_path"
  while [ "$search_path" != "/" ] && [ "${search_path%/}" != "$search_path" ]; do
    search_path="${search_path%/}"
  done
  local missing_suffix=""
  while [ ! -e "$search_path" ]; do
    local leaf_name="${search_path##*/}"
    if [ -z "$leaf_name" ] || [ "$leaf_name" = "/" ] || [ "$leaf_name" = "." ]; then
      break
    fi

    if [ -n "$missing_suffix" ]; then
      missing_suffix="${leaf_name}/${missing_suffix}"
    else
      missing_suffix="$leaf_name"
    fi

    local parent_path="${search_path%/*}"
    [ -n "$parent_path" ] || parent_path="/"
    while [ "$parent_path" != "/" ] && [ "${parent_path%/}" != "$parent_path" ]; do
      parent_path="${parent_path%/}"
    done
    if [ "$parent_path" = "$search_path" ]; then
      break
    fi
    search_path="$parent_path"
  done

  local resolved_existing=""
  _capture_resolve_existing_path resolved_existing "$search_path" || return 1

  local resolved_path="$resolved_existing"
  if [ -n "$missing_suffix" ]; then
    resolved_path="${resolved_existing%/}/${missing_suffix}"
  fi

  _capture_collapse_absolute_path resolved_path "$resolved_path" || return 1
  printf -v "$__var" '%s' "$resolved_path"
}

function start_capture() {
  # The regular module loader supplies these helpers. Keep direct callers that
  # source this command file working without adding load-time side effects.
  if ! declare -F _capture_build_filter >/dev/null 2>&1; then
    # shellcheck source=lib/capture/filter_helpers.sh
    source "$(dirname "${BASH_SOURCE[0]}")/filter_helpers.sh" || return 1
  fi
  local out_dir="$CAPTURE_DIR" scope="" backend_input="" client_input="" tls_decrypt="false"
  local scope_given=false backends_given=false clients_given=false folder_given=false options_done=false
  local option="" value=""

  while [ $# -gt 0 ]; do
    if [ "$options_done" = true ]; then
      if [ "$folder_given" = true ]; then
        echo "[Error] Unexpected start-capture argument: '$1'. Specify one output folder." >&2
        return 1
      fi
      out_dir="$1"
      folder_given=true
      shift
      continue
    fi
    case "$1" in
    --scope | --backends | --clients | --folder)
      option="$1"
      if [ $# -lt 2 ] || [[ "$2" == -* ]]; then
        echo "[Error] ${option} requires a value." >&2
        return 1
      fi
      value="$2"
      case "$option" in
      --scope) scope="$value"; scope_given=true ;;
      --backends) backend_input="$value"; backends_given=true ;;
      --clients) client_input="$value"; clients_given=true ;;
      --folder) out_dir="$value"; folder_given=true ;;
      esac
      shift 2
      ;;
    --tls-decrypt)
      tls_decrypt="true"
      shift
      ;;
    --)
      options_done=true
      shift
      ;;
    -*)
      echo "[Error] Unknown start-capture option: '$1'." >&2
      return 1
      ;;
    *)
      if [ "$folder_given" = true ]; then
        echo "[Error] Unexpected start-capture argument: '$1'. Specify one output folder." >&2
        return 1
      fi
      out_dir="$1"
      folder_given=true
      shift
      ;;
    esac
  done

  if [ -z "$out_dir" ]; then
    echo "[Error] The capture output folder must not be empty." >&2
    return 1
  fi
  if [ "$backends_given" = true ]; then
    _capture_split_targets "$backend_input"
    if [ ${#CAPTURE_TOKENS[@]} -eq 0 ]; then
      echo "[Error] --backends requires at least one backend domain; omit it to select all configured backends." >&2
      return 1
    fi
  fi
  if [ "$clients_given" = true ]; then
    _capture_split_targets "$client_input"
    if [ ${#CAPTURE_TOKENS[@]} -eq 0 ]; then
      echo "[Error] --clients requires at least one client IPv4 address." >&2
      return 1
    fi
  fi
  if [ "$scope_given" = true ]; then
    _capture_normalize_scope "$scope" || return 1
    scope="$CAPTURE_SCOPE"
  elif [ "$clients_given" = true ] && [ "$backends_given" = true ]; then
    scope="clients-backends"
  elif [ "$clients_given" = true ]; then
    scope="clients"
  elif [ "$backends_given" = true ]; then
    scope="backends"
  else
    scope="all"
  fi

  local capture_image="${CAPTURE_IMAGE:-}"
  if ! is_valid_image_ref "$capture_image"; then
    echo "[Error] Invalid packet capture image reference: ${capture_image}" >&2
    return 1
  fi

  if [ "$INTERACTIVE" = true ]; then
    local scope_idx=""
    if ! choose_option scope_idx "Capture scope?" \
      "All Nginx traffic (clients and backends)" \
      "Specific backend(s)" \
      "Specific client IP(s) (any backend)" \
      "Specific client IP(s) to backend(s)"; then
      return 1
    fi
    case "$scope_idx" in
    0) scope="all" ;;
    1) scope="backends" ;;
    2) scope="clients" ;;
    3) scope="clients-backends" ;;
    *)
      echo "[Error] Invalid capture scope selection." >&2
      return 1
      ;;
    esac
    if [ "$scope" = backends ] || [ "$scope" = clients-backends ]; then
      _capture_read_backend_rows || return 1
      echo "[Info] Available backends: ${CAPTURE_AVAILABLE_BACKENDS[*]}"
      _capture_read_selection "Enter backend domains (comma/space-separated, blank=all configured backends): " backend_input || return 1
    fi
    if [ "$scope" = clients ] || [ "$scope" = clients-backends ]; then
      _capture_read_selection "Enter client IPv4 addresses (comma/space-separated; required): " client_input || return 1
    fi
  fi

  # Resolve every requested restriction before creating capture directories,
  # changing TLS decrypt state, or replacing an existing capture container.
  _capture_build_filter "$scope" "$backend_input" "$client_input" || return 1
  local -a filter_args=() backend_targets=() uniq_client_ips=()
  if [ ${#CAPTURE_FILTER_ARGS[@]} -gt 0 ]; then
    filter_args=("${CAPTURE_FILTER_ARGS[@]}")
  fi
  if [ ${#CAPTURE_BACKEND_TARGETS[@]} -gt 0 ]; then
    backend_targets=("${CAPTURE_BACKEND_TARGETS[@]}")
  fi
  if [ ${#CAPTURE_CLIENT_HOSTS[@]} -gt 0 ]; then
    uniq_client_ips=("${CAPTURE_CLIENT_HOSTS[@]}")
  fi

  if [ "$INTERACTIVE" = true ] && ! _capture_is_true "$tls_decrypt"; then
    local decrypt_choice=""
    _capture_read_selection "Enable TLS decrypt capture (stores TLS session keys)? [y/N]: " decrypt_choice || return 1
    decrypt_choice="$(printf '%s' "${decrypt_choice:-n}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$decrypt_choice" =~ ^(y|yes)$ ]]; then
      tls_decrypt="true"
    fi
  fi

  if [[ "$out_dir" != /* ]]; then
    local rel="$out_dir"
    rel="${rel#./}"
    rel="${rel%/}"

    # If the relative path already points to the configured capture root
    # (e.g. state/pcaps or state/pcaps/subdir), keep it canonical.
    local candidate="${BASE_DIR%/}/${rel}"
    case "$candidate" in
    "$CAPTURE_DIR" | "$CAPTURE_DIR"/*)
      out_dir="$candidate"
      ;;
    *)
      # Support short aliases while keeping captures under CAPTURE_DIR.
      if [[ "$rel" == pcaps ]]; then
        rel=""
      elif [[ "$rel" == pcaps/* ]]; then
        rel="${rel#pcaps/}"
      elif [[ "$rel" == state/pcaps ]]; then
        rel=""
      elif [[ "$rel" == state/pcaps/* ]]; then
        rel="${rel#state/pcaps/}"
      fi

      if [ -n "$rel" ]; then
        out_dir="${CAPTURE_DIR}/${rel}"
      else
        out_dir="${CAPTURE_DIR}"
      fi
      ;;
    esac
  fi

  # Validate without touching output while an older capture may still write it.
  local capture_helper_dir=""
  capture_helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  if ! declare -F _capture_with_runtime_lock >/dev/null 2>&1; then
    # shellcheck source=lib/capture/lifecycle.sh
    source "$capture_helper_dir/lifecycle.sh" || return 1
  fi
  if ! declare -F _capture_output_preflight >/dev/null 2>&1; then
    # shellcheck source=lib/capture/output_paths.sh
    source "$capture_helper_dir/output_paths.sh" || return 1
  fi
  if ! declare -F _capture_tls_launch_begin >/dev/null 2>&1; then
    # shellcheck source=lib/capture/tls_launch.sh
    source "$capture_helper_dir/tls_launch.sh" || return 1
  fi
  _capture_output_preflight "$CAPTURE_DIR" "$out_dir" || return 1
  require_managed_nginx_container "start-capture" || return 1
  if ! container_running "$NGINX_CONTAINER_NAME"; then
    echo "[Error] Nginx container is not running." >&2
    return 1
  fi
  local decrypt_context=""
  if _capture_is_true "$tls_decrypt"; then
    decrypt_context="command=start-capture scope=${scope:-auto} backends=${backend_input:-all} clients=${client_input:-all}"
    acknowledge_tls_decrypt_capture "$decrypt_context" || return 1
    _capture_tls_launch_preflight || return 1
  fi

  local info_parts=()
  if [ "$scope" = "backends" ]; then
    info_parts+=("backends: ${backend_targets[*]:-all}")
  elif [ "$scope" = "clients" ]; then
    info_parts+=("clients: ${uniq_client_ips[*]:-all}")
  elif [ "$scope" = "clients-backends" ]; then
    info_parts+=("clients: ${uniq_client_ips[*]:-all}")
    info_parts+=("backends: ${backend_targets[*]:-all}")
  else
    info_parts+=("full traffic")
  fi
  info_parts+=("image: ${capture_image}")
  if _capture_is_true "$tls_decrypt"; then
    info_parts+=("tls-decrypt: enabled")
  fi
  if [ "${#filter_args[@]}" -gt 0 ]; then
    _capture_with_runtime_lock _capture_start_runtime "$out_dir" "$tls_decrypt" \
      "$decrypt_context" "$capture_image" "scope: ${scope}; ${info_parts[*]}" "${filter_args[@]}"
  else
    _capture_with_runtime_lock _capture_start_runtime "$out_dir" "$tls_decrypt" \
      "$decrypt_context" "$capture_image" "scope: ${scope}; ${info_parts[*]}"
  fi
}

function _capture_start_runtime() {
  local out_dir="$1" tls_decrypt="$2" decrypt_context="$3" capture_image="$4" capture_info="$5"
  shift 5
  local removed=false full_dir="" output_identity="" timestamp="" pcap_file="" keylog_file=""
  # Recheck under the lock: preflight may have raced another finished command.
  _capture_output_preflight "$CAPTURE_DIR" "$out_dir" || return 1
  require_managed_nginx_container "start-capture" || return 1
  if ! container_running "$NGINX_CONTAINER_NAME"; then
    echo "[Error] Nginx container is not running." >&2
    return 1
  fi
  if _capture_is_true "$tls_decrypt"; then
    _capture_tls_launch_preflight || return 1
  fi
  # The old container must no longer be able to rename mount children before
  # any output mkdir/chmod, including the descriptor-based preparation below.
  _capture_remove_existing removed || return 1
  if [ "$removed" = true ]; then
    echo "[Info] Previous packet capture removed; existing capture files retained."
  fi
  _capture_output_prepare full_dir output_identity "$CAPTURE_DIR" "$out_dir" || return 1
  timestamp="$(date '+%Y%m%d_%H%M%S')" || return 1
  pcap_file="${timestamp}_nginx.pcap"
  CAPTURE_TLS_LAUNCH_ACTIVE=false
  if _capture_is_true "$tls_decrypt"; then
    _capture_tls_launch_begin "$decrypt_context" || return 1
    echo "[Warn] TLS decrypt capture enabled for this session. Session keys are sensitive and stored with restricted permissions."
    if capture_tls_keylog_file keylog_file 2>/dev/null; then
      echo "[Info] TLS key log file: ${keylog_file}"
    fi
  fi
  if ! _capture_output_verify "$CAPTURE_DIR" "$out_dir" "$output_identity"; then
    _capture_tls_launch_abort || true
    return 1
  fi
  local -a docker_cmd=(docker run -d --name nginx-capture)
  if [ "${CAPTURE_TLS_LAUNCH_ACTIVE:-false}" = true ]; then
    docker_cmd+=(--cidfile "$CAPTURE_TLS_LAUNCH_WORKSPACE/capture.cid")
  fi
  docker_cmd+=(--net=container:"$NGINX_CONTAINER_NAME" -v "$full_dir":/pcaps
    "$capture_image" tcpdump -U -i any -s0 -w "/pcaps/${pcap_file}")
  if [ "$#" -gt 0 ]; then docker_cmd+=("$@"); fi
  local capture_status=0
  "${docker_cmd[@]}" || capture_status=$?
  if [ "$capture_status" -ne 0 ]; then
    echo "[Error] Failed to start the packet capture container." >&2
    _capture_tls_launch_abort || true
    return "$capture_status"
  fi
  _capture_tls_launch_finish || return 1
  echo "[Info] Packet capture started (${capture_info}). Output: ${full_dir}/${pcap_file}"
}
