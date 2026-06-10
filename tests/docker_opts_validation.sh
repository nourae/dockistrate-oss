#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backends.sh
source "$ROOT_DIR/lib/backends.sh"

assert_rejected() {
  local opts="$1" profile="${2:-backend}"
  if normalize_docker_opts_for_storage "$opts" "docker opts parsing test" "$profile" >/dev/null; then
    printf 'Expected docker opts to be rejected but they were allowed (profile=%s): %s\n' "$profile" "$opts" >&2
    exit 1
  fi
}

assert_allowed() {
  local opts="$1" profile="${2:-backend}"
  if ! normalize_docker_opts_for_storage "$opts" "docker opts parsing test" "$profile" >/dev/null; then
    printf 'Expected docker opts to be allowed but they were rejected (profile=%s): %s\n' "$profile" "$opts" >&2
    exit 1
  fi
}

assert_allowed "--privileged" backend
assert_allowed "--cap-add=SYS_ADMIN" backend
assert_allowed "--cap-add SYS_PTRACE" backend
assert_allowed "-v /:/host" backend
assert_allowed "--mount type=bind,source=/,target=/host" backend
assert_allowed "--security-opt=seccomp=unconfined" backend
assert_allowed "-e FOO=bar --cap-add=NET_BIND_SERVICE" backend
assert_allowed "--cpus 1.5" backend
assert_rejected "--network host" backend
assert_rejected "--name backend-custom" backend
assert_rejected "--rm" backend
assert_rejected "--cpus" backend
assert_rejected "--memory" backend
assert_rejected "--cpus --cap-add SYS_ADMIN" backend
assert_rejected "alpine" backend
assert_rejected "--privileged alpine" backend
assert_rejected "-- --env FOO=bar" backend

assert_allowed "--privileged" nginx
assert_allowed "--cap-add=SYS_ADMIN" nginx
assert_allowed "--security-opt=seccomp=unconfined" nginx
assert_allowed "--cpus 1.5" nginx
assert_allowed "--label app=demo" nginx
assert_allowed "-l owner=ops" nginx
assert_rejected "--publish 18180:80" nginx
assert_rejected "-p 18180:80" nginx
assert_rejected "--publish-all" nginx
assert_rejected "--volume /tmp:/tmp" nginx
assert_rejected "-v /tmp:/tmp" nginx
assert_rejected "--mount type=bind,source=/tmp,target=/tmp" nginx
assert_rejected "--entrypoint /bin/sh" nginx
assert_rejected "--network host" nginx
assert_rejected "--name nginx-custom" nginx
assert_rejected "--rm" nginx
assert_rejected "--cpus" nginx
assert_rejected "--memory" nginx
assert_rejected "--cpus --cap-add SYS_ADMIN" nginx
assert_rejected "alpine" nginx
assert_rejected "--privileged alpine" nginx
assert_rejected "-- --env FOO=bar" nginx
assert_rejected "--label com.dockistrate.managed=false" nginx
assert_rejected "--label=com.dockistrate.state-dir=/tmp/foreign" nginx
assert_rejected "-l com.dockistrate.role=proxy" nginx

assert_rejected "--label \"unterminated" backend
assert_rejected $'--env "FOO=bar\tbaz"' backend

normalized="$(normalize_docker_opts_for_storage $'--label app=demo \\\n--env \"FOO=bar baz\"' "docker opts parsing test" "backend")"
expected_normalized="--label app=demo --env 'FOO=bar baz'"
if [ "$normalized" != "$expected_normalized" ]; then
  printf 'Expected normalized options to be %s but got %s\n' "$expected_normalized" "$normalized" >&2
  exit 1
fi

printf 'Docker option parsing checks passed.\n'
