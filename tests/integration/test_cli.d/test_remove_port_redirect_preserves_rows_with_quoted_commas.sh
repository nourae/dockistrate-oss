#!/usr/bin/env bash

test_remove_port_redirect_preserves_rows_with_quoted_commas() {
  local domain="quoted-remove-redirect.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9400 http >/dev/null
  assertEquals "seed backend for quoted remove redirect test" 0 $?

  run_dockistrate add-port "$domain" 443 9400 https none no >/dev/null
  assertEquals "seed https mapping for quoted remove redirect test" 0 $?

  run_dockistrate set-port-redirect "$domain" 80 on 301 >/dev/null
  assertEquals "enable redirect before remove test" 0 $?

  local src_dir="${CERTS_DIR}/selfsigned/live/${domain}_443"
  local quoted_rel="custom/live/remove,cert_443"
  local quoted_abs="${CERTS_DIR}/${quoted_rel}"
  mkdir -p "$quoted_abs"
  cp "${src_dir}/fullchain.pem" "${quoted_abs}/fullchain.pem"
  cp "${src_dir}/privkey.pem" "${quoted_abs}/privkey.pem"
  chmod 640 "${quoted_abs}/fullchain.pem"
  chmod 600 "${quoted_abs}/privkey.pem"

  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  local rewritten_file="${TMP_DIR}/backend_ports_remove_redirect_quoted.csv"
  : >"$rewritten_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "port,${domain},,,,,443,9400,https,"*)
      printf '%s\n' "port,${domain},,,,,443,9400,https,\"${quoted_rel}\",no,off,,off,auto,,,,,," >>"$rewritten_file"
      ;;
    *)
      printf '%s\n' "$line" >>"$rewritten_file"
      ;;
    esac
  done <"$ports_file"
  mv "$rewritten_file" "$ports_file"

  local https_row_before
  https_row_before="$(grep -F "port,${domain},,,,,443,9400,https," "$ports_file")"

  local output
  output="$(run_dockistrate remove-port-redirect "$domain" 80)"
  assertEquals "remove-port-redirect should succeed with quoted cert_ref rows present" 0 $?
  assertStringContains "remove-port-redirect output" "Redirect disabled for ${domain} on port 80." "$output"

  assertFileContains "port,${domain},,,,,80,9400,http,none,no,off," "$ports_file"

  local https_row_after
  https_row_after="$(grep -F "port,${domain},,,,,443,9400,https," "$ports_file")"
  assertEquals "quoted https row should remain unchanged after redirect removal" "$https_row_before" "$https_row_after"
}
