# shellcheck shell=bash

# Build filtered operator choices for a selected field with contextual examples
# Returns newline-separated "cond|Alias — desc. Example: <field> <cond> <value>"
function build_condition_choices_for_selector() {
  local src="$1" name="${2:-}"
  # Compute selector string as understood by security_rules helpers
  local selector
  if [[ -z "$name" || "$name" == "-" ]]; then
    selector="$(_sr_source_to_selector "$src")"
  else
    selector="$(_sr_source_to_selector "$src" "$name")"
  fi
  local allowed
  allowed="$(_sr_allowed_ops_for_selector "$selector")"
  # Helper: field label used in examples
  local field_label
  case "$src" in
  header) field_label="header ${name:-X-Name}" ;;
  cookie) field_label="cookie ${name:-session}" ;;
  arg) field_label="arg ${name:-token}" ;;
  method) field_label="method -" ;;
  path) field_label="path" ;;
  uri) field_label="uri" ;;
  host) field_label="host" ;;
  scheme) field_label="scheme -" ;;
  ip)
    case "${name:-l7}" in
    l3 | real | realip) field_label="ip l3" ;;
    *) field_label="ip l7" ;;
    esac
    ;;
  tls_sni) field_label="tls_sni" ;;
  tls_protocol) field_label="tls_protocol" ;;
  var) field_label="var ${name:-request_length}" ;;
  *) field_label="$src" ;;
  esac
  # Helper: description per operator (matches arg_option_hint)
  local desc cond
  # Split allowed ops safely even if IFS is altered elsewhere
  local -a _allowed_arr
  IFS=' ' read -r -a _allowed_arr <<<"$allowed"
  for cond in "${_allowed_arr[@]}"; do
    case "$cond" in
    equals) desc="string equals" ;;
    not_equals) desc="string not equal" ;;
    contains) desc="substring present (case-insensitive)" ;;
    not_contains) desc="substring not present" ;;
    starts_with) desc="string starts with" ;;
    not_starts_with) desc="string does not start with" ;;
    ends_with) desc="string ends with" ;;
    not_ends_with) desc="string does not end with" ;;
    matches) desc="regex matches (case-insensitive)" ;;
    not_matches) desc="regex does not match" ;;
    in) desc="value is in list (comma or pipe separated)" ;;
    not_in) desc="value is not in list" ;;
    gt) desc="numeric greater than" ;;
    ge) desc="numeric greater or equal" ;;
    lt) desc="numeric less than" ;;
    le) desc="numeric less or equal" ;;
    exists) desc="value present / header exists" ;;
    not_exists) desc="value missing / header not present" ;;
    *) desc="condition" ;;
    esac
    # Example value tuned per selector
    local ex_val
    case "$src" in
    method)
      case "$cond" in in) ex_val="GET,POST" ;; *) ex_val="POST" ;; esac
      ;;
    scheme) ex_val="https" ;;
    host | tls_sni)
      case "$cond" in
      ends_with | not_ends_with) ex_val=".internal" ;;
      starts_with | not_starts_with) ex_val="api." ;;
      in | not_in) ex_val="admin.example.com,ops.example.com" ;;
      *) ex_val="api.example.com" ;;
      esac
      ;;
    path | uri)
      case "$cond" in
      ends_with | not_ends_with) ex_val=".json" ;;
      starts_with | not_starts_with) ex_val="/admin" ;;
      contains | not_contains) ex_val="/api/" ;;
      *) ex_val="/health" ;;
      esac
      ;;
    header | cookie | arg)
      case "$cond" in
      in | not_in) ex_val="a,b,c" ;;
      matches | not_matches) ex_val="^[A-Za-z0-9]+$" ;;
      contains | not_contains) ex_val="debug" ;;
      starts_with | not_starts_with) ex_val="prefix" ;;
      ends_with | not_ends_with) ex_val="suffix" ;;
      exists | not_exists) ex_val="-" ;;
      *) ex_val="prod" ;;
      esac
      ;;
    ip)
      case "$cond" in
      in | not_in) ex_val="192.168.1.10,10.0.0.5" ;;
      *) ex_val="192.168.1.10" ;;
      esac
      ;;
    tls_protocol)
      case "$cond" in in) ex_val="TLSv1.2,TLSv1.3" ;; *) ex_val="TLSv1.2" ;; esac
      ;;
    var)
      case "$cond" in
      gt | ge | lt | le) ex_val="100000" ;;
      in | not_in) ex_val="1|2|3" ;;
      matches | not_matches) ex_val="^[A-Za-z0-9]+$" ;;
      exists | not_exists) ex_val="-" ;;
      *) ex_val="foo" ;;
      esac
      ;;
    *) ex_val="value" ;;
    esac
    local alias
    alias="$(condition_alias "$cond")"
    printf '%s|%s — %s. Example: %s %s %s\n' "$cond" "$alias" "$desc" "$field_label" "$cond" "$ex_val"
  done
}
