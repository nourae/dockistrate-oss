#!/usr/bin/env bash

test_list_certs_handles_quoted_cert_ref_usage() {
  local domain="quoted-list-certs.test"
  run_dockistrate add-backend "$domain" nginx:alpine 9401 http >/dev/null
  assertEquals "seed backend for list-certs quoted usage test" 0 $?

  run_dockistrate add-port "$domain" 4443 9401 https none no >/dev/null
  assertEquals "seed https mapping for list-certs quoted usage test" 0 $?

  local src_dir="${CERTS_DIR}/selfsigned/live/${domain}_4443"
  local quoted_folder="listusage,cert_4443"
  local quoted_rel="custom/live/${quoted_folder}"
  local quoted_abs="${CERTS_DIR}/${quoted_rel}"
  mkdir -p "$quoted_abs"
  cp "${src_dir}/fullchain.pem" "${quoted_abs}/fullchain.pem"
  cp "${src_dir}/privkey.pem" "${quoted_abs}/privkey.pem"
  chmod 640 "${quoted_abs}/fullchain.pem" "${quoted_abs}/privkey.pem"

  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  local rewritten_file="${TMP_DIR}/backend_ports_list_certs_quoted.csv"
  : >"$rewritten_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "port,${domain},,,,,4443,9401,https,"*)
      printf '%s\n' "port,${domain},,,,,4443,9401,https,\"${quoted_rel}\",no,off,,off,auto,,,,,," >>"$rewritten_file"
      ;;
    *)
      printf '%s\n' "$line" >>"$rewritten_file"
      ;;
    esac
  done <"$ports_file"
  mv "$rewritten_file" "$ports_file"

  local output
  output="$(run_dockistrate list-certs)"
  assertEquals "list-certs should succeed with quoted cert_ref rows" 0 $?

  local matched_line
  matched_line="$(printf '%s\n' "$output" | grep -E "^${quoted_folder}[[:space:]]*\\|" || true)"
  if [ -z "$matched_line" ]; then
    fail "list-certs output missing quoted-comma folder entry:\n${output}"
  fi
  assertStringContains "list-certs should include mapped HTTPS port for quoted cert_ref" "| 4443" "$matched_line"
}
