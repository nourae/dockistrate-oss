#!/usr/bin/env bash

test_remove_path_option_preserves_rows_with_quoted_commas() {
  local domain="quoted-remove-path.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9201 http >/dev/null
  assertEquals "seed backend for quoted remove-path-option test" 0 $?

  run_dockistrate add-path-option "$domain" 80 /api --ws yes --redirect off --headers none >/dev/null
  assertEquals "seed path option for quoted remove-path-option test" 0 $?

  run_dockistrate add-port "$domain" 443 9201 https none no >/dev/null
  assertEquals "seed https mapping for quoted remove-path-option test" 0 $?

  local src_dir="${CERTS_DIR}/selfsigned/live/${domain}_443"
  local quoted_rel="custom/live/remove,path_443"
  local quoted_abs="${CERTS_DIR}/${quoted_rel}"
  mkdir -p "$quoted_abs"
  cp "${src_dir}/fullchain.pem" "${quoted_abs}/fullchain.pem"
  cp "${src_dir}/privkey.pem" "${quoted_abs}/privkey.pem"
  chmod 640 "${quoted_abs}/fullchain.pem" "${quoted_abs}/privkey.pem"

  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  local rewritten_file="${TMP_DIR}/backend_ports_remove_path_quoted.csv"
  : >"$rewritten_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "port,${domain},,,,,443,9201,https,"*)
      printf '%s\n' "port,${domain},,,,,443,9201,https,\"${quoted_rel}\",no,off,,off,auto,,,,,," >>"$rewritten_file"
      ;;
    *)
      printf '%s\n' "$line" >>"$rewritten_file"
      ;;
    esac
  done <"$ports_file"
  mv "$rewritten_file" "$ports_file"

  local https_row_before
  https_row_before="$(grep -F "port,${domain},,,,,443,9201,https," "$ports_file")"

  local output
  output="$(run_dockistrate remove-path-option "$domain" 80 /api)"
  assertEquals "remove-path-option should succeed with quoted cert_ref rows present" 0 $?
  assertStringContains "remove-path-option output" "Removed path override ${domain}:80/api." "$output"

  if grep -Fq "path,${domain},,,/api,,80,,,,yes,off," "$ports_file"; then
    fail "remove-path-option should remove the target path row"
  fi

  local https_row_after
  https_row_after="$(grep -F "port,${domain},,,,,443,9201,https," "$ports_file")"
  assertEquals "quoted https row should remain unchanged after path removal" "$https_row_before" "$https_row_after"
}
