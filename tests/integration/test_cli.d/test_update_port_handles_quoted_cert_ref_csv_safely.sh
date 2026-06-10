#!/usr/bin/env bash

test_update_port_handles_quoted_cert_ref_csv_safely() {
  local domain="quoted-update-port.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9000 http >/dev/null
  assertEquals "seed backend for quoted update-port test" 0 $?

  run_dockistrate add-port "$domain" 8443 9000 https none no >/dev/null
  assertEquals "seed https mapping for quoted update-port test" 0 $?

  mkdir -p "${CERTS_DIR}/custom/live/comma,cert_443"

  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  local rewritten_file="${TMP_DIR}/backend_ports_update_port_quoted.csv"
  : >"$rewritten_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "port,${domain},,,,,8443,9000,https,"*)
      printf '%s\n' "port,${domain},,,,,8443,9000,https,\"custom/live/comma,cert_443\",no,off,,off,auto,,,,,," >>"$rewritten_file"
      ;;
    *)
      printf '%s\n' "$line" >>"$rewritten_file"
      ;;
    esac
  done <"$ports_file"
  mv "$rewritten_file" "$ports_file"

  local output
  output="$(run_dockistrate update-port "$domain" 8443 --container-port 9100)"
  assertEquals "update-port should succeed with quoted cert_ref rows present" 0 $?
  assertStringContains "update-port output" "Updated port mapping for ${domain} on 8443." "$output"

  assertFileContains "port,${domain},,,,,8443,9100,https,\"custom/live/comma,cert_443\",no,off,,off,auto,,,,,," "$ports_file"
}
