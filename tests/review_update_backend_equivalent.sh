#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=helpers/interactive_audit_fixture.sh
source "$ROOT_DIR/tests/helpers/interactive_audit_fixture.sh"
VISIBILITY_POLICY=full
actual="$(_review_command_cli_equivalent update-backend primary.example.com nginx:alpine 8080 '' dockistrate-net)"
[ "$actual" = './dockistrate.sh update-backend primary.example.com --image nginx:alpine --container-port 8080 --network dockistrate-net' ] || fail_test "Managed CLI equivalent is invalid: $actual"
actual="$(_review_command_cli_equivalent update-backend primary.example.com __DEFAULT__ __DEFAULT__ __DOCKER_OPTS_CLEAR__ __DEFAULT__)"
[ "$actual" = "./dockistrate.sh update-backend primary.example.com --docker-opts ''" ] || fail_test 'Keep-current forced image replacement or lost explicit clear'
actual="$(_review_command_cli_equivalent update-backend primary.example.com --image nginx:alpine)"
[ "$actual" = './dockistrate.sh update-backend primary.example.com --image nginx:alpine' ] || fail_test 'Existing CLI flags changed'
actual="$(_review_command_cli_equivalent update-backend primary.example.com nginx:alpine 80 '' dockistrate-net aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)"
[[ "$actual" == *'--replace-unmanaged-container aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]] || fail_test 'Explicit replacement ID was lost'
echo '[tests] review_update_backend_equivalent.sh: PASS'
