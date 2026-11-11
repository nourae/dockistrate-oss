# shellcheck shell=bash

if [ "$#" -eq 0 ]; then
  failed=0
  for test_case in "${CASES[@]}"; do
    if "$BASH" "$PROJECTION_CASE_RUNNER" --case "$test_case"; then
      printf '[tests] PASS: %s %s\n' "$PROJECTION_TEST_LABEL" "$test_case"
    else
      printf '[tests] FAIL: %s %s\n' "$PROJECTION_TEST_LABEL" "$test_case" >&2
      failed=1
    fi
  done
  [ "$failed" -ne 0 ] || printf '%s checks passed (%s cases).\n' "$PROJECTION_TEST_LABEL" "${#CASES[@]}"
  exit "$failed"
fi
[ "$#" -eq 2 ] && [ "$1" = --case ] || exit 2
case_found=false
for test_case in "${CASES[@]}"; do [ "$test_case" != "$2" ] || case_found=true; done
[ "$case_found" = true ] || exit 2
CASE_LABEL="$2"

# shellcheck source=tests/lib/nginx_certificate_projection_fixture.sh
source "$ROOT_DIR/tests/lib/nginx_certificate_projection_fixture.sh"
# shellcheck source=tests/lib/nginx_certificate_projection_runtime.sh
source "$ROOT_DIR/tests/lib/nginx_certificate_projection_runtime.sh"
if [ "$PROJECTION_CASE_FUNCTION" = test_projection_rollback ]; then
  # shellcheck source=tests/lib/nginx_certificate_projection_rollback.sh
  source "$ROOT_DIR/tests/lib/nginx_certificate_projection_rollback.sh"
fi
"$PROJECTION_CASE_FUNCTION" "$2"
