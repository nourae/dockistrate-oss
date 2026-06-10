#!/usr/bin/env bash

test_update_backend_preserves_rows_with_quoted_commas() {
  local domain="quoted-update-backend.test"
  run_dockistrate add-backend "$domain" nginx:alpine 7101 http >/dev/null
  assertEquals "seed backend for quoted update-backend test" 0 $?

  run_dockistrate add-port "$domain" 8443 7101 https none no >/dev/null
  assertEquals "seed https mapping for quoted update-backend test" 0 $?

  local src_dir="${CERTS_DIR}/selfsigned/live/${domain}_8443"
  local quoted_rel="custom/live/update,cert_8443"
  local quoted_abs="${CERTS_DIR}/${quoted_rel}"
  mkdir -p "$quoted_abs"
  cp "${src_dir}/fullchain.pem" "${quoted_abs}/fullchain.pem"
  cp "${src_dir}/privkey.pem" "${quoted_abs}/privkey.pem"
  chmod 640 "${quoted_abs}/fullchain.pem" "${quoted_abs}/privkey.pem"

  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  local rewritten_file="${TMP_DIR}/backend_ports_update_backend_quoted.csv"
  : >"$rewritten_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "port,${domain},,,,,8443,7101,https,"*)
      printf '%s\n' "port,${domain},,,,,8443,7101,https,\"${quoted_rel}\",no,off,,off,auto,,,,,," >>"$rewritten_file"
      ;;
    *)
      printf '%s\n' "$line" >>"$rewritten_file"
      ;;
    esac
  done <"$ports_file"
  mv "$rewritten_file" "$ports_file"

  local output
  output="$(run_dockistrate update-backend "$domain" --container-port 7201)"
  assertEquals "update-backend should succeed with quoted cert_ref rows" 0 $?
  assertStringContains "update-backend output" "Backend '${domain}' updated." "$output"

  assertFileContains "backend,${domain},127.0.0.1:7201,dockistrate-net,,,,,,,,," "$ports_file"
  assertFileContains "port,${domain},,,,,80,7201,http,none,no,off," "$ports_file"
  assertFileContains "port,${domain},,,,,8443,7201,https,\"${quoted_rel}\",no,off,,off,auto,,,,,," "$ports_file"
}
