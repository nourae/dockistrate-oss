#!/usr/bin/env bash

test_remove_cert_dependency_scan_handles_quoted_cert_ref() {
  local domain="guarded-quoted.test"
  run_dockistrate add-cert "$domain" 9443 selfsigned >/dev/null
  assertEquals "add-cert should succeed" 0 $?

  run_dockistrate add-backend "$domain" nginx:alpine 9501 http >/dev/null
  assertEquals "add-backend should succeed" 0 $?

  run_dockistrate add-port "$domain" 9443 9501 https "selfsigned/live/${domain}_9443" no >/dev/null
  assertEquals "add-port should succeed" 0 $?

  local src_dir="${CERTS_DIR}/selfsigned/live/${domain}_9443"
  local quoted_rel="selfsigned/live/${domain}_9443,extra"
  local quoted_abs="${CERTS_DIR}/${quoted_rel}"
  mkdir -p "$quoted_abs"
  cp "${src_dir}/fullchain.pem" "${quoted_abs}/fullchain.pem"
  cp "${src_dir}/privkey.pem" "${quoted_abs}/privkey.pem"
  chmod 640 "${quoted_abs}/fullchain.pem" "${quoted_abs}/privkey.pem"

  local ports_file="${CONFIG_DIR}/backend_ports.csv"
  local rewritten_file="${TMP_DIR}/backend_ports_remove_cert_dep_quoted.csv"
  : >"$rewritten_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "port,${domain},,,,,9443,9501,https,"*)
      printf '%s\n' "port,${domain},,,,,9443,9501,https,\"${quoted_rel}\",no,off,,off,auto,,,,,," >>"$rewritten_file"
      ;;
    *)
      printf '%s\n' "$line" >>"$rewritten_file"
      ;;
    esac
  done <"$ports_file"
  mv "$rewritten_file" "$ports_file"

  local remove_output remove_status
  remove_output="$(run_dockistrate remove-cert "$domain" 9443)"
  remove_status=$?

  assertEquals "remove-cert should succeed when only quoted-comma cert_ref rows are present" 0 "$remove_status"
  assertTrue "remove-cert output should not report dependency false-positive" "[[ \"$remove_output\" != *\"depend on it\"* ]]"
  assertTrue "original certificate directory should be removed" "[ ! -d \"${src_dir}\" ]"
}
