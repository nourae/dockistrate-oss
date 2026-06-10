#!/usr/bin/env bash

test_list_port_mappings_handles_quoted_cert_ref_csv_safely() {
  local domain="quoted-list-ports.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9301 http >/dev/null
  assertEquals "seed backend for list-port-mappings quoted test" 0 $?

  run_dockistrate add-port "$domain" 8443 9301 https none no >/dev/null
  assertEquals "seed https mapping for list-port-mappings quoted test" 0 $?

  local src_dir="${CERTS_DIR}/selfsigned/live/${domain}_8443"
  local quoted_rel="custom/live/list,cert_8443"
  local quoted_abs="${CERTS_DIR}/${quoted_rel}"
  mkdir -p "$quoted_abs"
  cp "${src_dir}/fullchain.pem" "${quoted_abs}/fullchain.pem"
  cp "${src_dir}/privkey.pem" "${quoted_abs}/privkey.pem"
  chmod 640 "${quoted_abs}/fullchain.pem" "${quoted_abs}/privkey.pem"

  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  local rewritten_file="${TMP_DIR}/backend_ports_list_mapping_quoted.csv"
  : >"$rewritten_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "port,${domain},,,,,8443,9301,https,"*)
      printf '%s\n' "port,${domain},,,,,8443,9301,https,\"${quoted_rel}\",no,off,,off,auto,,,,,," >>"$rewritten_file"
      ;;
    *)
      printf '%s\n' "$line" >>"$rewritten_file"
      ;;
    esac
  done <"$ports_file"
  mv "$rewritten_file" "$ports_file"

  local output
  output="$(run_dockistrate list-port-mappings)"
  assertEquals "list-port-mappings should succeed with quoted cert_ref rows" 0 $?
  assertStringContains "list-port-mappings output should keep ws/redirect aligned" \
    "${domain} 8443 -> 9301 proto=https ws=no cert=${quoted_rel} redirect=off" "$output"
}
