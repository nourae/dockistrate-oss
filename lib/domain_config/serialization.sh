# shellcheck shell=bash

# Canonical rows ignore CSV quote style, CRLF, file order, and absent optional
# tables. Ordering is explicit in the schema rather than an accident of disk.
function domain_config_canonicalize() {
  local config_dir="${1:-}" filename="" rows="" line="" position=0
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  # Unknown files are invalid source, not formatting differences. In particular,
  # command guards must not treat an extra file as an unchanged accepted draft.
  for filename in "$config_dir"/* "$config_dir"/.[!.]* "$config_dir"/..?*; do
    [ -e "$filename" ] || [ -L "$filename" ] || continue
    _domain_csv_schema "${filename##*/}" || return 1
  done
  while IFS= read -r filename; do
    rows="$(_domain_csv_read "$config_dir/$filename" _domain_config_canonical_row)" || return 1
    [ -n "$rows" ] || continue
    printf '[%s]\n' "$filename"
    if [ "$filename" = docker_options.csv ]; then
      rows="$(printf '%s\n' "$rows" | LC_ALL=C sort -t, -k1,1n)" || return 1
      position=0
      while IFS= read -r line; do
        csv_parse_line "$line" || return 1
        position=$((position + 1)); csv_join_row "$position" "${CSV_FIELDS[1]}" || return 1
      done <<<"$rows"
    else
      printf '%s\n' "$rows" | LC_ALL=C sort || return 1
    fi
  done < <(domain_config_files)
}

function _domain_config_canonical_row() {
  local filename="${1##*/}"
  shift 2
  case "$filename" in
  domain.csv) [ "$1" != target ] || [ -n "$2" ] || return 0 ;;
  backend.csv)
    case "$1:$2" in state:running | "network:${DEFAULT_NETWORK:-dockistrate-net}") return 0 ;; esac
    ;;
  settings.csv)
    case "$1" in client_ip_header | proxy_ip_header)
      if [ -z "$2" ]; then csv_join_row "$1" off; return; fi
      ;;
    esac
    ;;
  inheritance.csv) [ "$2" != yes ] || return 0 ;;
  mtls.csv)
    case "$1:$2" in enabled:no | directory: | directory:"${STATE_DIR}/domains/"*/mtls) return 0 ;; esac
    ;;
  port_options.csv)
    case "$3:$4" in websocket:no | redirect_enabled:off | redirect_code: | http3_enabled:off | alt_svc:auto) return 0 ;; esac
    ;;
  path_options.csv)
    case "$2:$3" in websocket:inherit | websocket: | redirect_enabled:inherit | redirect_enabled: | redirect_code: | reason:- | reason: | source_location:auto | source_location:) return 0 ;; esac
    ;;
  paths.csv) csv_join_row "$1" "$2" "$3" "${4:-prefix}" "${5:-100}" "$6" "${7:-none}" "$8"; return ;;
  security_rules.csv) csv_join_row "$1" "$2" "$3" "${4:-require}" "$5" "${6:--}" "${7:--}" "${8:-auto}"; return ;;
  esac
  csv_join_row "$@"
}

function _domain_csv_write_header() {
  local destination="${1:-}"
  _domain_csv_schema "${destination##*/}" || return 1
  [ ! -L "$destination" ] || return 1
  printf '%s\n' "$DOMAIN_CSV_HEADER" >"$destination" || return 1
  _tighten_file_permissions "$destination" 600
}

function _domain_csv_initialize() {
  local destination="${1:-}" filename=""
  [ ! -L "$destination" ] || return 1
  mkdir -p "$destination" || return 1
  while IFS= read -r filename; do
    _domain_csv_write_header "$destination/$filename" || return 1
  done < <(domain_config_files)
}

function domain_config_write_template() {
  local domain="${1:-}" kind="${2:-backend}" destination="${3:-}"
  is_valid_domain "$domain" && [ "$domain" = "$(normalize_domain "$domain")" ] || return 1
  case "$kind" in backend | alias | dedicated | certificate-only) ;; *) return 1 ;; esac
  _domain_csv_initialize "$destination" || return 1
  _domain_csv_set "$destination/domain.csv" schema_version "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" || return 1
  _domain_csv_set "$destination/domain.csv" role "$kind" || return 1
  case "$kind" in
  backend)
    _domain_csv_set "$destination/backend.csv" image '' || return 1
    _domain_csv_set "$destination/backend.csv" container_port 8080 || return 1
    _domain_csv_set "$destination/backend.csv" network "${DEFAULT_NETWORK:-dockistrate-net}" || return 1
    _domain_csv_set "$destination/backend.csv" state running || return 1
    ;;
  alias | dedicated) _domain_csv_set "$destination/domain.csv" target '' || return 1 ;;
  esac
}
