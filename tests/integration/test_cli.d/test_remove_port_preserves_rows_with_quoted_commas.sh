#!/usr/bin/env bash

test_remove_port_preserves_rows_with_quoted_commas() {
  local domain="quoted-remove-port.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9100 http >/dev/null
  assertEquals "seed backend for quoted remove-port test" 0 $?

  run_dockistrate add-port "$domain" 8081 9100 http none no >/dev/null
  assertEquals "seed extra http mapping for quoted remove-port test" 0 $?

  run_dockistrate add-port "$domain" 8443 9100 https none no >/dev/null
  assertEquals "seed https mapping for quoted remove-port test" 0 $?

  local src_dir="${CERTS_DIR}/selfsigned/live/${domain}_8443"
  local quoted_rel="custom/live/remove,port_8443"
  local quoted_abs="${CERTS_DIR}/${quoted_rel}"
  mkdir -p "$quoted_abs"
  cp "${src_dir}/fullchain.pem" "${quoted_abs}/fullchain.pem"
  cp "${src_dir}/privkey.pem" "${quoted_abs}/privkey.pem"
  chmod 640 "${quoted_abs}/fullchain.pem" "${quoted_abs}/privkey.pem"

  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  local rewritten_file="${TMP_DIR}/backend_ports_remove_port_quoted.csv"
  : >"$rewritten_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "port,${domain},,,,,8443,9100,https,"*)
      printf '%s\n' "port,${domain},,,,,8443,9100,https,\"${quoted_rel}\",no,off,,off,auto,,,,,," >>"$rewritten_file"
      ;;
    *)
      printf '%s\n' "$line" >>"$rewritten_file"
      ;;
    esac
  done <"$ports_file"
  mv "$rewritten_file" "$ports_file"

  local https_row_before
  https_row_before="$(grep -F "port,${domain},,,,,8443,9100,https," "$ports_file")"

  local output
  output="$(run_dockistrate remove-port "$domain" 8081)"
  assertEquals "remove-port should succeed with quoted cert_ref rows present" 0 $?
  assertStringContains "remove-port output" "Removed port mapping for domain=${domain} on port=8081." "$output"

  if grep -Fq "port,${domain},,,,,8081,9100,http,none,no,off," "$ports_file"; then
    fail "remove-port should remove the target http mapping on 8081"
  fi

  local https_row_after
  https_row_after="$(grep -F "port,${domain},,,,,8443,9100,https," "$ports_file")"
  assertEquals "quoted https row should remain unchanged after removing another port" "$https_row_before" "$https_row_after"
}
