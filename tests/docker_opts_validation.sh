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

# Only the five ownership labels are reserved; admin options and other labels
# remain valid. Cover Docker's short, attached, equal and bundled spellings.
for label in managed role state-dir backend-domain backend-launch; do
  for opts in "--label com.dockistrate.$label=foreign" "--label=com.dockistrate.$label=foreign" \
    "-l com.dockistrate.$label=foreign" "-lcom.dockistrate.$label=foreign" \
    "-il=com.dockistrate.$label=foreign" "-il com.dockistrate.$label=foreign"; do
    assert_rejected "$opts" backend
  done
done
assert_allowed '--label com.dockistrate.operator=team --label com.dockistrate.backend-launch-note=operator' backend
assert_allowed '--label-file /tmp/operator-labels' backend

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
assert_allowed "-lapp=demo" nginx
assert_allowed "-ilapp=demo" nginx
assert_allowed "-il app=demo" nginx
assert_allowed "-im 128m" nginx
assert_allowed "-ePUBLISH_HINT=-p" nginx
assert_allowed "-m128m" nginx
assert_allowed "-itq" nginx
assert_rejected "--publish 18180:80" nginx
assert_rejected "-p 18180:80" nginx
assert_rejected "-ip18180:80" nginx
assert_rejected "-itp18180:80" nginx
assert_rejected "--publish-all" nginx
assert_rejected "-iP" nginx
assert_rejected "--volume /tmp:/tmp" nginx
assert_rejected "-v /tmp:/tmp" nginx
assert_rejected "-iv/tmp:/tmp" nginx
assert_rejected "-itv/tmp:/tmp" nginx
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
assert_rejected "-l=com.dockistrate.role=proxy" nginx
assert_rejected "-ilcom.dockistrate.managed=false" nginx
assert_rejected "-il=com.dockistrate.state-dir=/tmp/foreign" nginx
assert_rejected "-il com.dockistrate.role=proxy" nginx

assert_rejected "--label \"unterminated" backend
assert_rejected $'--env "FOO=bar\tbaz"' backend

# Boolean options introduced after the original validator must never consume
# the following positional image. Keep deliberate privileged operator choices.
for profile in backend nginx; do
  for flag in --use-api-socket --disable-content-trust; do
    assert_allowed "$flag" "$profile"
    assert_allowed "$flag=true" "$profile"
    assert_allowed "$flag=false" "$profile"
    assert_rejected "$flag payload.example/alternate:latest" "$profile"
    assert_rejected "$flag=false payload.example/alternate:latest" "$profile"
  done
  assert_allowed '--use-api-socket --cpus 1.5 --disable-content-trust=false' "$profile"
  assert_rejected '--future-option payload.example/alternate:latest' "$profile"
  assert_rejected '--future-option' "$profile"
  assert_allowed '--future-option=value' "$profile"
  assert_allowed '--future-option=' "$profile"
  assert_rejected '--future-option=value payload.example/alternate:latest' "$profile"
  assert_rejected '-Z value' "$profile"
  assert_rejected '-iZ value' "$profile"
  assert_rejected '-Z=value' "$profile"
  assert_allowed '-it=false --cpus 1' "$profile"
  assert_allowed '-it=true --env=FOO=bar' "$profile"
  assert_rejected '-it=false payload.example/alternate:latest' "$profile"
  assert_allowed '-ie FOO=bar -il owner=ops -im128m' "$profile"
  assert_allowed '-ieFOO=--publish -ilowner=--volume' "$profile"
  assert_rejected '-ie' "$profile"
  assert_rejected '-im --privileged' "$profile"
  assert_allowed '--env= --label= -e=' "$profile"
  assert_rejected '--env --privileged' "$profile"
  assert_rejected '-- --use-api-socket' "$profile"
done

assert_rejected '--net=host' backend
assert_rejected '--net=host' nginx
assert_rejected '-ip8080:80' nginx
assert_rejected '-iv/tmp:/work' nginx
assert_rejected '-ilcom.dockistrate.managed=true' nginx
assert_allowed '-ip8080:80 -iv/tmp:/work --entrypoint=--literal' backend

# A rejection remains safe to display with the configured visibility policy.
VISIBILITY_POLICY=redacted
secret_marker='DOCKER_OPTION_SECRET_9f3a'
if output="$(normalize_docker_opts_for_storage "--use-api-socket $secret_marker" 'docker opts test' nginx 2>&1)"; then
  printf 'Expected positional token rejection in redacted mode\n' >&2
  exit 1
fi
case "$output" in
*"$secret_marker"*) printf 'Rejected Docker option leaked its value in redacted mode\n' >&2; exit 1 ;;
esac
case "$output" in
*'[REDACTED]'*) ;;
*) printf 'Rejected Docker option did not use the redaction marker\n' >&2; exit 1 ;;
esac
VISIBILITY_POLICY=full

normalized="$(normalize_docker_opts_for_storage $'--label app=demo \\\n--env \"FOO=bar baz\"' "docker opts parsing test" "backend")"
expected_normalized="--label app=demo --env 'FOO=bar baz'"
if [ "$normalized" != "$expected_normalized" ]; then
  printf 'Expected normalized options to be %s but got %s\n' "$expected_normalized" "$normalized" >&2
  exit 1
fi

printf 'Docker option parsing checks passed.\n'
