#!/usr/bin/env bash

test_set_ws_flag_preserves_rows_with_quoted_commas() {
  local domain="quoted-ws-flag.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9300 http >/dev/null
  assertEquals "seed backend for quoted ws flag test" 0 $?

  run_dockistrate add-port "$domain" 443 9300 https none no >/dev/null
  assertEquals "seed https mapping for quoted ws flag test" 0 $?

  local src_dir="${CERTS_DIR}/selfsigned/live/${domain}_443"
  local quoted_rel="custom/live/ws,cert_443"
  local quoted_abs="${CERTS_DIR}/${quoted_rel}"
  mkdir -p "$quoted_abs"
  cp "${src_dir}/fullchain.pem" "${quoted_abs}/fullchain.pem"
  cp "${src_dir}/privkey.pem" "${quoted_abs}/privkey.pem"
  chmod 640 "${quoted_abs}/fullchain.pem"
  chmod 600 "${quoted_abs}/privkey.pem"

  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  local rewritten_file="${TMP_DIR}/backend_ports_ws_quoted.csv"
  : >"$rewritten_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "port,${domain},,,,,443,9300,https,"*)
      printf '%s\n' "port,${domain},,,,,443,9300,https,\"${quoted_rel}\",no,off,,off,auto,,,,,," >>"$rewritten_file"
      ;;
    *)
      printf '%s\n' "$line" >>"$rewritten_file"
      ;;
    esac
  done <"$ports_file"
  mv "$rewritten_file" "$ports_file"

  local output
  output="$(run_dockistrate enable-ws "$domain" 443)"
  assertEquals "enable-ws should succeed with quoted cert_ref rows present" 0 $?
  assertStringContains "enable-ws output" "WebSocket enabled for ${domain} on port 443." "$output"
  assertFileContains "port,${domain},,,,,443,9300,https,\"${quoted_rel}\",yes,off,,off,auto,,,,,," "$ports_file"

  output="$(run_dockistrate disable-ws "$domain" 443)"
  assertEquals "disable-ws should succeed with quoted cert_ref rows present" 0 $?
  assertStringContains "disable-ws output" "WebSocket disabled for ${domain} on port 443." "$output"
  assertFileContains "port,${domain},,,,,443,9300,https,\"${quoted_rel}\",no,off,,off,auto,,,,,," "$ports_file"
}
