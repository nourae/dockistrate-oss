#!/usr/bin/env bash

test_renew_certs_handles_quoted_cert_ref_paths() {
  local domain="quoted-renew-certs.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9500 http >/dev/null
  assertEquals "seed backend for renew-certs quoted path test" 0 $?

  run_dockistrate add-port "$domain" 9443 9500 https none no >/dev/null
  assertEquals "seed https mapping for renew-certs quoted path test" 0 $?

  local src_dir="${CERTS_DIR}/selfsigned/live/${domain}_9443"
  local quoted_rel="custom/live/comma,renew_9443"
  local quoted_abs="${CERTS_DIR}/${quoted_rel}"
  mkdir -p "$quoted_abs"
  cp "${src_dir}/fullchain.pem" "${quoted_abs}/fullchain.pem"
  cp "${src_dir}/privkey.pem" "${quoted_abs}/privkey.pem"
  chmod 640 "${quoted_abs}/fullchain.pem" "${quoted_abs}/privkey.pem"

  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  local rewritten_file="${TMP_DIR}/backend_ports_renew_quoted.csv"
  : >"$rewritten_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "port,${domain},,,,,9443,9500,https,"*)
      printf '%s\n' "port,${domain},,,,,9443,9500,https,\"${quoted_rel}\",no,off,,off,auto,,,,,," >>"$rewritten_file"
      ;;
    *)
      printf '%s\n' "$line" >>"$rewritten_file"
      ;;
    esac
  done <"$ports_file"
  mv "$rewritten_file" "$ports_file"

  local output
  output="$(run_dockistrate renew-certs)"
  assertEquals "renew-certs should succeed with quoted cert_ref paths" 0 $?
  assertStringContains "renew-certs should report quoted cert path" "${quoted_rel} expires on" "$output"

  if printf '%s\n' "$output" | grep -Fq "Skipping invalid certificate path"; then
    fail "renew-certs should not report an invalid cert path for quoted-comma rows:\n${output}"
  fi
}
