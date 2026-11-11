#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=helpers/interactive_audit_fixture.sh
source "$ROOT_DIR/tests/helpers/interactive_audit_fixture.sh"
all_hosts=$'alias.example.com\ndedicated.example.com\nprimary.example.com'
server_hosts=$'dedicated.example.com\nprimary.example.com'
for command in add-backend-header update-backend-header remove-all-backend-headers set-backend-hsts set-backend-csp add-acl; do
  [ "$(get_arg_choices "$command" domain)" = "$all_hosts" ] || fail_test "$command omits an independent host identity"
done
for command in enable-backend-mtls set-backend-http-version set-backend-client-ip-header set-backend-proxy-ip-header; do
  [ "$(get_arg_choices "$command" domain)" = "$server_hosts" ] || fail_test "$command has unsupported/missing server identities"
done
[ "$(get_arg_choices start-backend domain)" = primary.example.com ] || fail_test 'Host expansion leaked into container commands'
chosen=''
choose_http_domain chosen < <(printf '2\n') || fail_test 'Header host chooser failed'
[ "$chosen" = dedicated.example.com ] || fail_test 'Dedicated header target not selectable'
choose_http_domain chosen < <(printf '1\n') || fail_test 'Alias header chooser failed'
[ "$chosen" = alias.example.com ] || fail_test 'Alias header target not selectable'
echo '[tests] interactive_host_choices.sh: PASS'
