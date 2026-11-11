#!/usr/bin/env bash

# Keep fixture-only test functions out of shunit's test discovery.
function integration_domain_csv_set() (
  # shellcheck source=tests/helpers/domain_csv.sh
  source "$ROOT_DIR/tests/helpers/domain_csv.sh"
  test_domain_csv_set "$@"
)

function integration_runtime_csv_set() (
  source "$ROOT_DIR/lib/utils.sh"
  source "$ROOT_DIR/lib/permissions/common.sh"
  source "$ROOT_DIR/lib/domain_config/model.sh"
  source "$ROOT_DIR/lib/domain_config/runtime_records.sh"
  local file="$1"
  shift
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || return 1
    _domain_runtime_put "$file" "$1" "$2" || return 1
    shift 2
  done
)

# Seed accepted source with legal quoted cells. Certificate IDs are deliberately
# path-safe in schema 4; comma/quote escaping belongs in actual free-text values.
function integration_rewrite_quoted_listener_fixture() (
  source "$ROOT_DIR/lib/utils/csv.sh"
  local file="$1" port="$2" domain="$3" cert_id="$4" line="" prefix="" suffix=""
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  IFS= read -r line <"$file" || return 1
  printf '%s\n' "$line"
  local line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1)); [ "$line_no" -gt 1 ] || continue
    csv_parse_line "$line" || return 1
    [ "$CSV_FIELD_COUNT" -eq 10 ] || return 1
    if [ "${CSV_FIELDS[0]}" = "$port" ] && [ "${CSV_FIELDS[2]}" = https ]; then
      prefix="$(csv_join_row "${CSV_FIELDS[@]:0:3}")" || return 1
      suffix="$(csv_join_row "${CSV_FIELDS[@]:5}")" || return 1
      printf '%s,"%s","%s",%s\n' "$prefix" "$domain" "$cert_id" "$suffix"
    else
      printf '%s\n' "$line"
    fi
  done <"$file"
)

function integration_seed_quoted_domain_fixture() {
  local domain="$1" port="$2" cert_id="${3:-selfsigned-$2}" directory="" temporary=""
  for directory in "$STATE_DIR/domains/$domain/config" "$STATE_DIR/domains/$domain/runtime/applied"; do
    temporary="$directory/ports.fixture"
    integration_rewrite_quoted_listener_fixture "$directory/ports.csv" "$port" "$domain" "$cert_id" >"$temporary" || return 1
    mv "$temporary" "$directory/ports.csv" || return 1
    printf '%s\n' 'response,X-CSV-Fixture,"comma, ""quoted"""' >>"$directory/headers.csv" || return 1
  done
}

function integration_assert_quoted_domain_fixture() {
  local domain="$1"
  assertFileContains "${domain},response,X-CSV-Fixture,\"comma, \"\"quoted\"\"\"" "$CONFIG_DIR/backend_headers.csv"
  assertFileContains 'response,X-CSV-Fixture,"comma, ""quoted"""' "$STATE_DIR/domains/$domain/config/headers.csv"
}

function integration_seed_letsencrypt_fixture() {
  local domain="$1" port="$2" source="$STATE_DIR/domains/$1/certs/selfsigned-$2"
  local destination="$STATE_DIR/domains/$1/certs/letsencrypt-$2" directory="" temporary=""
  mkdir -p "$destination" "$STATE_DIR/shared/acme/live/$domain" || return 1
  cp "$source/fullchain.pem" "$source/privkey.pem" "$destination/" || return 1
  cp "$source/fullchain.pem" "$source/privkey.pem" "$STATE_DIR/shared/acme/live/$domain/" || return 1
  printf 'provider,port_suffix,source_ref,declared,specification,source_fullchain,source_privkey\nletsencrypt,%s,,yes,,,\n' "$port" >"$destination/certificate.csv" || return 1
  for directory in "$STATE_DIR/domains/$domain/config" "$STATE_DIR/domains/$domain/runtime/applied"; do
    printf 'letsencrypt-%s,letsencrypt,%s,,\n' "$port" "$port" >>"$directory/certificates.csv" || return 1
    temporary="$directory/ports.fixture"
    integration_rewrite_quoted_listener_fixture "$directory/ports.csv" "$port" "$domain" "letsencrypt-$port" >"$temporary" || return 1
    mv "$temporary" "$directory/ports.csv" || return 1
  done
}
