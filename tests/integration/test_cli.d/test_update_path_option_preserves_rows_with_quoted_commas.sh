#!/usr/bin/env bash

test_update_path_option_preserves_rows_with_quoted_commas() {
  local domain="quoted-path-update.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9200 http >/dev/null
  assertEquals "seed backend for quoted path update test" 0 $?

  run_dockistrate add-path-option "$domain" 80 /api --ws yes --redirect off --headers none >/dev/null
  assertEquals "seed path override for quoted path update test" 0 $?

  run_dockistrate add-port "$domain" 443 9200 https none no >/dev/null
  assertEquals "seed https mapping for quoted path update test" 0 $?

  local src_dir="${CERTS_DIR}/selfsigned/live/${domain}_443"
  local quoted_rel="custom/live/path,cert_443"
  local quoted_abs="${CERTS_DIR}/${quoted_rel}"
  mkdir -p "$quoted_abs"
  cp "${src_dir}/fullchain.pem" "${quoted_abs}/fullchain.pem"
  cp "${src_dir}/privkey.pem" "${quoted_abs}/privkey.pem"
  chmod 640 "${quoted_abs}/fullchain.pem"
  chmod 600 "${quoted_abs}/privkey.pem"

  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  local rewritten_file="${TMP_DIR}/backend_ports_update_path_quoted.csv"
  : >"$rewritten_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "port,${domain},,,,,443,9200,https,"*)
      printf '%s\n' "port,${domain},,,,,443,9200,https,\"${quoted_rel}\",no,off,,off,auto,,,,,," >>"$rewritten_file"
      ;;
    *)
      printf '%s\n' "$line" >>"$rewritten_file"
      ;;
    esac
  done <"$ports_file"
  mv "$rewritten_file" "$ports_file"

  local https_row_before
  https_row_before="$(grep -F "port,${domain},,,,,443,9200,https," "$ports_file")"

  local output
  output="$(run_dockistrate update-path-option "$domain" 80 /api --new-path /v2 --ws no --redirect 301 --headers none)"
  assertEquals "update-path-option should succeed with quoted cert_ref rows present" 0 $?
  assertStringContains "update-path-option output" "Updated path override ${domain}:80/v2." "$output"

  assertFileContains "path,${domain},,,/v2,,80,,,,no,on,301" "$ports_file"

  local https_row_after
  https_row_after="$(grep -F "port,${domain},,,,,443,9200,https," "$ports_file")"
  assertEquals "quoted https row should remain unchanged after path update" "$https_row_before" "$https_row_after"
}
