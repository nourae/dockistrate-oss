#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backends.sh
source "$ROOT_DIR/lib/backends.sh"

mount_result="$(_parse_docker_opts_to_lines "--mount source=\"C:\\code\"" "regression check")"
expected_mount="source=C:\\code"

if ! grep -Fxq "$expected_mount" <<<"$mount_result"; then
  printf 'Expected mount to contain %s but got:%s\n' "$expected_mount" "\n$mount_result" >&2
  exit 1
fi

literal_result="$(_parse_docker_opts_to_lines "\"line\\\\break\"" "regression check")"
expected_literal='line\break'

if [ "$literal_result" != "$expected_literal" ]; then
  printf 'Expected literal sequence to remain %s but got %s\n' "$expected_literal" "$literal_result" >&2
  exit 1
fi

continuation_result="$(_parse_docker_opts_to_lines $'--cap-add SYS_ADMIN \\\n--security-opt seccomp=unconfined' "regression check")"
expected_continuation=$'--cap-add\nSYS_ADMIN\n--security-opt\nseccomp=unconfined'

if [ "$continuation_result" != "$expected_continuation" ]; then
  printf 'Expected docs-style continuation parse to be:%s\nbut got:%s\n' "\n$expected_continuation" "\n$continuation_result" >&2
  exit 1
fi

crlf_result="$(_parse_docker_opts_to_lines $'--label app=demo\r\n--network host' "regression check")"
expected_crlf=$'--label\napp=demo\n--network\nhost'

if [ "$crlf_result" != "$expected_crlf" ]; then
  printf 'Expected CRLF parsing result:%s\nbut got:%s\n' "\n$expected_crlf" "\n$crlf_result" >&2
  exit 1
fi

json_array_result="$(_parse_docker_opts_to_lines '-e ARR=["a","b"]' "regression check")"
expected_json_array=$'-e\nARR=["a","b"]'

if [ "$json_array_result" != "$expected_json_array" ]; then
  printf 'Expected JSON array assignment parse result:%s\nbut got:%s\n' "\n$expected_json_array" "\n$json_array_result" >&2
  exit 1
fi

json_array_with_space_result="$(_parse_docker_opts_to_lines '-e ARR=["hello world","b"]' "regression check")"
expected_json_array_with_space=$'-e\nARR=["hello world","b"]'

if [ "$json_array_with_space_result" != "$expected_json_array_with_space" ]; then
  printf 'Expected JSON array-with-space assignment parse result:%s\nbut got:%s\n' "\n$expected_json_array_with_space" "\n$json_array_with_space_result" >&2
  exit 1
fi

json_object_result="$(_parse_docker_opts_to_lines '-e JSON={"a":"b"}' "regression check")"
expected_json_object=$'-e\nJSON={"a":"b"}'

if [ "$json_object_result" != "$expected_json_object" ]; then
  printf 'Expected JSON object assignment parse result:%s\nbut got:%s\n' "\n$expected_json_object" "\n$json_object_result" >&2
  exit 1
fi

json_object_with_space_result="$(_parse_docker_opts_to_lines '-e JSON={"a":"hello world"}' "regression check")"
expected_json_object_with_space=$'-e\nJSON={"a":"hello world"}'

if [ "$json_object_with_space_result" != "$expected_json_object_with_space" ]; then
  printf 'Expected JSON object-with-space assignment parse result:%s\nbut got:%s\n' "\n$expected_json_object_with_space" "\n$json_object_with_space_result" >&2
  exit 1
fi

json_object_with_escaped_quote_result="$(_parse_docker_opts_to_lines '-e JSON={"a":"say \"hi\""}' "regression check")"
expected_json_object_with_escaped_quote=$'-e\nJSON={"a":"say \\"hi\\""}'

if [ "$json_object_with_escaped_quote_result" != "$expected_json_object_with_escaped_quote" ]; then
  printf 'Expected JSON object-with-escaped-quote assignment parse result:%s\nbut got:%s\n' "\n$expected_json_object_with_escaped_quote" "\n$json_object_with_escaped_quote_result" >&2
  exit 1
fi

raw_multiline_opts=$'--label app=demo \\\n--env "FOO=bar baz"\r\n--cap-add SYS_PTRACE'
normalized_opts="$(normalize_docker_opts_for_storage "$raw_multiline_opts" "regression check")"
expected_normalized="--label app=demo --env 'FOO=bar baz' --cap-add SYS_PTRACE"

if [ "$normalized_opts" != "$expected_normalized" ]; then
  printf 'Expected normalized opts %s but got %s\n' "$expected_normalized" "$normalized_opts" >&2
  exit 1
fi

normalized_json_array="$(normalize_docker_opts_for_storage '-e ARR=["a","b"]' "regression check")"
expected_normalized_json_array="-e 'ARR=[\"a\",\"b\"]'"

if [ "$normalized_json_array" != "$expected_normalized_json_array" ]; then
  printf 'Expected normalized JSON array opts %s but got %s\n' "$expected_normalized_json_array" "$normalized_json_array" >&2
  exit 1
fi

normalized_json_array_with_space="$(normalize_docker_opts_for_storage '-e ARR=["hello world","b"]' "regression check")"
expected_normalized_json_array_with_space="-e 'ARR=[\"hello world\",\"b\"]'"

if [ "$normalized_json_array_with_space" != "$expected_normalized_json_array_with_space" ]; then
  printf 'Expected normalized JSON array-with-space opts %s but got %s\n' "$expected_normalized_json_array_with_space" "$normalized_json_array_with_space" >&2
  exit 1
fi

normalized_json_object="$(normalize_docker_opts_for_storage '-e JSON={"a":"b"}' "regression check")"
expected_normalized_json_object="-e 'JSON={\"a\":\"b\"}'"

if [ "$normalized_json_object" != "$expected_normalized_json_object" ]; then
  printf 'Expected normalized JSON object opts %s but got %s\n' "$expected_normalized_json_object" "$normalized_json_object" >&2
  exit 1
fi

normalized_json_object_with_space="$(normalize_docker_opts_for_storage '-e JSON={"a":"hello world"}' "regression check")"
expected_normalized_json_object_with_space="-e 'JSON={\"a\":\"hello world\"}'"

if [ "$normalized_json_object_with_space" != "$expected_normalized_json_object_with_space" ]; then
  printf 'Expected normalized JSON object-with-space opts %s but got %s\n' "$expected_normalized_json_object_with_space" "$normalized_json_object_with_space" >&2
  exit 1
fi

normalized_json_object_with_escaped_quote="$(normalize_docker_opts_for_storage '-e JSON={"a":"say \"hi\""}' "regression check")"
expected_normalized_json_object_with_escaped_quote="-e 'JSON={\"a\":\"say \\\"hi\\\"\"}'"

if [ "$normalized_json_object_with_escaped_quote" != "$expected_normalized_json_object_with_escaped_quote" ]; then
  printf 'Expected normalized JSON object-with-escaped-quote opts %s but got %s\n' "$expected_normalized_json_object_with_escaped_quote" "$normalized_json_object_with_escaped_quote" >&2
  exit 1
fi

normalized_mid_token_quotes="$(normalize_docker_opts_for_storage '-e FOO="bar baz"' "regression check")"
expected_mid_token_quotes="-e 'FOO=bar baz'"

if [ "$normalized_mid_token_quotes" != "$expected_mid_token_quotes" ]; then
  printf 'Expected non-JSON mid-token quotes to normalize to %s but got %s\n' "$expected_mid_token_quotes" "$normalized_mid_token_quotes" >&2
  exit 1
fi

old_backend_opts_file="${BACKEND_DOCKER_OPTS_FILE-__unset__}"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.XXXXXX")"
BACKEND_DOCKER_OPTS_FILE="${tmp_dir}/backend_docker_opts.csv"
trap 'rm -rf "$tmp_dir"; if [ "$old_backend_opts_file" = "__unset__" ]; then unset BACKEND_DOCKER_OPTS_FILE; else BACKEND_DOCKER_OPTS_FILE="$old_backend_opts_file"; fi' EXIT

cat >"$BACKEND_DOCKER_OPTS_FILE" <<'EOF_OPTS'
key,docker_options
backend:example.com,opts
backend:examplecom.com,opts
EOF_OPTS
set_backend_docker_opts "backend:example.com" ""

remaining_contents="$(cat "$BACKEND_DOCKER_OPTS_FILE")"

if grep -Fxq 'backend:example.com,opts' <<<"$remaining_contents"; then
  printf 'Expected backend:example.com entry to be removed but file still contains:%s\n' "\n$remaining_contents" >&2
  exit 1
fi

if ! grep -Fxq 'backend:examplecom.com,opts' <<<"$remaining_contents"; then
  printf 'Expected backend:examplecom.com entry to remain but file now contains:%s\n' "\n$remaining_contents" >&2
  exit 1
fi

set_backend_docker_opts "backend:normalized.test" "$normalized_opts"
stored_normalized="$(get_backend_docker_opts "backend:normalized.test")"

if [ "$stored_normalized" != "$normalized_opts" ]; then
  printf 'Expected normalized docker opts to round-trip exactly. expected=%s got=%s\n' "$normalized_opts" "$stored_normalized" >&2
  exit 1
fi

if [[ "$stored_normalized" == *$'\n'* ]]; then
  printf 'Expected normalized docker opts to remain single-line but got:%s\n' "\n$stored_normalized" >&2
  exit 1
fi

get_mode() {
  local target="$1" mode=""
  if mode=$(stat -c '%a' "$target" 2>/dev/null); then
    printf '%s' "$mode"
    return 0
  fi
  stat -f '%Lp' "$target"
}

opts_file_mode="$(get_mode "$BACKEND_DOCKER_OPTS_FILE")"
if [ "$opts_file_mode" != "600" ]; then
  printf 'Expected backend docker opts file mode 600 but got %s\n' "$opts_file_mode" >&2
  exit 1
fi

printf 'Docker option parsing regression checks passed.\n'
