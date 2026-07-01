#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/arg_choices_images.sh
source "$ROOT_DIR/lib/cli/arg_choices_images.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-choice-parse.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

function assert_eq() {
  local actual="${1:-}" expected="${2:-}" msg="${3:-assertion failed}"
  if [ "$actual" != "$expected" ]; then
    echo "[Error] ${msg}: expected '${expected}', got '${actual}'." >&2
    exit 1
  fi
}

rule_choice='10|AND int-sec.example.com (n=3),header:User-Agent contains IntBot,method equals GET,path starts_with /interactive'
v=""
l=""
cli_choice_line_to_value_label "$rule_choice" v l
assert_eq "$v" "10" "pipe choice value must remain numeric id"
assert_eq "$l" "AND int-sec.example.com (n=3),header:User-Agent contains IntBot,method equals GET,path starts_with /interactive" "pipe choice label must preserve commas"

csv_choice='and,AND (all conditions)'
v=""
l=""
cli_choice_line_to_value_label "$csv_choice" v l
assert_eq "$v" "and" "csv choice value should parse as first field"
assert_eq "$l" "AND (all conditions)" "csv choice label should parse as second field"

csv_choice_with_pipe='not_matches,"Not Matches — regex does not match. Example: header X-Agent not_matches (curl|wget)"'
v=""
l=""
cli_choice_line_to_value_label "$csv_choice_with_pipe" v l
assert_eq "$v" "not_matches" "csv choice value should not be truncated when label contains pipe"
assert_eq "$l" "Not Matches — regex does not match. Example: header X-Agent not_matches (curl|wget)" "csv choice label should preserve pipe characters"

# Guard against output-var collisions with parser internal variable names.
parsed_value=""
parsed_label=""
cli_choice_line_to_value_label "port|Port (server)" parsed_value parsed_label
assert_eq "$parsed_value" "port" "output value must populate even with parsed_value var name"
assert_eq "$parsed_label" "Port (server)" "output label must populate even with parsed_label var name"

docker_choice='repo/app:1.0|repo/app:1.0 (@abc123456789, created 2 days ago)'
v=""
l=""
cli_choice_line_to_value_label "$docker_choice" v l
assert_eq "$v" "repo/app:1.0" "pipe choice should win when image label contains a comma"
assert_eq "$l" "repo/app:1.0 (@abc123456789, created 2 days ago)" "image label should preserve repository name and created date"

mkdir -p "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/docker" <<'EOF_DOCKER'
#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${1:-}" = "image" ] && [ "${2:-}" = "ls" ]; then
  printf '%s\n' \
    'repo/app:1.0|sha256:abc123456789|2 days ago|' \
    'repo/other:latest|sha256:def123456789|3 weeks ago|repo/other@sha256:def123456789abcdef'
  exit 0
fi
exit 1
EOF_DOCKER
chmod +x "$TMP_DIR/bin/docker"

function get_backend_image() {
  printf '%s\n' 'current/backend:1.0'
}

CURRENT_ARGS=(example.com)
choices="$(PATH="$TMP_DIR/bin:$PATH" __arg_choices_image update-backend)"
image_choice="$(printf '%s\n' "$choices" | sed -n '/^repo\/app:1\.0|/p' | head -n 1)"
[ -n "$image_choice" ] || {
  echo "[Error] Expected update-backend image choices to include local Docker image repo/app:1.0." >&2
  printf '%s\n' "$choices" >&2
  exit 1
}
v=""
l=""
cli_choice_line_to_value_label "$image_choice" v l
assert_eq "$v" "repo/app:1.0" "update-backend image choice value should be the Docker image ref"
case "$l" in
repo/app:1.0*"created 2 days ago"*) ;;
*)
  echo "[Error] update-backend image choice label should include the image ref and created date, got '${l}'." >&2
  exit 1
  ;;
esac

echo "cli_choice_line_to_value_label pipe-with-commas guard checks passed."
