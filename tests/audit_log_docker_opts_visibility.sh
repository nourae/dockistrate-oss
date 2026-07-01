#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-audit-visibility.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../lib/logging/audit_log.sh
source "$ROOT_DIR/lib/logging/audit_log.sh"
# shellcheck source=../lib/utils/common.sh
source "$ROOT_DIR/lib/utils/common.sh"
# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/validators.sh
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck source=../lib/utils/operator_visibility.sh
source "$ROOT_DIR/lib/utils/operator_visibility.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/arg_metadata.sh
source "$ROOT_DIR/lib/cli/arg_metadata.sh"
# shellcheck source=../lib/cli/run_command.sh
source "$ROOT_DIR/lib/cli/run_command.sh"

AUDIT_LOG_FILE="$TMP_DIR/audit.log"
export AUDIT_LOG_FILE
DEFAULT_VISIBILITY_POLICY="full"
VISIBILITY_POLICY="full"

function get_arg_spec() {
  local cmd="${1:-}"
  case "$cmd" in
  add-backend)
    printf '%s' 'domain,;image,;container_port,;protocol,http;listen,;cert_path,;ws,no;docker_opts,;network,dockistrate-net;expose,yes'
    ;;
  update-backend)
    printf '%s' 'domain,;image,;container_port,;docker_opts,;network,dockistrate-net'
    ;;
  start-nginx)
    printf '%s' 'nginx_image,nginx:latest;docker_opts,'
    ;;
  set-nginx-docker-opts)
    printf '%s' 'docker_opts,'
    ;;
  add-header | update-header)
    printf '%s' 'req_resp,request;header,;value,'
    ;;
  set-hsts)
    printf '%s' 'hsts_value,'
    ;;
  set-csp)
    printf '%s' 'csp_value,'
    ;;
  show-visibility-policy | status)
    printf '%s' ''
    ;;
  *)
    return 1
    ;;
  esac
}

function record_audit_message() {
  audit_log "$(_run_command_audit_message "$@")"
}

record_audit_message add-backend example.com nginx:alpine 80 http 80 selfsigned yes "--env SECRET=top"
record_audit_message add-backend example.com nginx:alpine 80 http --listen 80 --cert selfsigned
record_audit_message update-backend example.com --docker-opts "--env TOKEN=hidden"
record_audit_message update-backend example.com --container-port 8080
record_audit_message start-nginx --docker-opts="--env NGINX_SECRET=hidden"
record_audit_message set-nginx-docker-opts "--env GLOBAL_SECRET=hidden"
record_audit_message set-nginx-docker-opts --env VARIADIC_SECRET=top --cpus 1
record_audit_message add-header response X-Token "Bearer HEADER_SECRET=hidden"
record_audit_message set-hsts "max-age=60; preload"
record_audit_message status
record_audit_message status --foo
record_audit_message show-visibility-policy

if grep -Fq '[REDACTED]' "$AUDIT_LOG_FILE"; then
  echo "[Error] Audit log unexpectedly redacted Docker options." >&2
  cat "$AUDIT_LOG_FILE" >&2
  exit 1
fi

for expected in \
  "add-backend example.com nginx:alpine 80 http 80 selfsigned yes --env SECRET=top" \
  "add-backend example.com nginx:alpine 80 http --listen 80 --cert selfsigned" \
  "update-backend example.com --docker-opts --env TOKEN=hidden" \
  "update-backend example.com --container-port 8080" \
  "start-nginx --docker-opts=--env NGINX_SECRET=hidden" \
  "set-nginx-docker-opts --env GLOBAL_SECRET=hidden" \
  "set-nginx-docker-opts --env VARIADIC_SECRET=top --cpus 1" \
  "add-header response X-Token Bearer HEADER_SECRET=hidden" \
  "set-hsts max-age=60; preload" \
  "status" \
  "status --foo" \
  "show-visibility-policy"; do
  if ! grep -Fq -- "$expected" "$AUDIT_LOG_FILE"; then
    echo "[Error] Audit log missing expected full context: $expected" >&2
    cat "$AUDIT_LOG_FILE" >&2
    exit 1
  fi
done

VISIBILITY_POLICY=redacted
: >"$AUDIT_LOG_FILE"
record_audit_message add-backend example.com nginx:alpine 80 http 80 selfsigned yes "--env SECRET=top"
record_audit_message update-backend example.com --docker-opts "--env TOKEN=hidden"
record_audit_message update-backend example.com --docker-opts __DOCKER_OPTS_CLEAR__
record_audit_message start-nginx --docker-opts="--env NGINX_SECRET=hidden"
record_audit_message start-nginx --docker-opts --env UNQUOTED_DOCKER_SECRET=hidden
record_audit_message start-nginx --docker-opts "" --env EMPTY_FLAG_DOCKER_SECRET=hidden
record_audit_message start-nginx --unknown-flag nginx:mainline --docker-opts "--env UNKNOWN_SHIFT_SECRET=hidden"
record_audit_message set-nginx-docker-opts "--env GLOBAL_SECRET=hidden"
record_audit_message set-nginx-docker-opts --env VARIADIC_SECRET=top --cpus 1
record_audit_message set-nginx-docker-opts "" --env EMPTY_FIRST_VARIADIC_SECRET=top --cpus 1
record_audit_message add-header response X-Token "Bearer HEADER_SECRET=hidden"
record_audit_message add-header response X-Token Bearer SPLIT_HEADER_SECRET=hidden
record_audit_message add-header --req-resp response --header X-Token --value "" Bearer EMPTY_FLAG_HEADER_SECRET=hidden
record_audit_message add-header --req-resp response --header X-Token MIXED_HEADER_SECRET=hidden
record_audit_message set-hsts "max-age=60; preload"
record_audit_message set-hsts off
record_audit_message set-hsts Off
record_audit_message set-csp off
record_audit_message set-csp OFF
record_audit_message add-backend example.com nginx:alpine 80 http --docker-opts "--env POST_BOUNDARY_SECRET=hidden" --no-expose
record_audit_message add-backend \
  --domain example.com \
  --image nginx:alpine \
  --container-port 80 \
  --protocol http \
  --listen 80 \
  --cert-path selfsigned \
  --ws yes \
  --network mynet \
  --docker-opts "--env SHIFT_SECRET=hidden"
record_audit_message start-nginx --docker-opts ""

if ! _run_command_has_sensitive_args set-nginx-docker-opts --env VARIADIC_SECRET=top --cpus 1; then
  echo "[Error] Sensitive-arg detector should flag variadic nginx docker opts." >&2
  exit 1
fi
if ! _run_command_has_sensitive_args set-nginx-docker-opts "" --env EMPTY_FIRST_VARIADIC_SECRET=top --cpus 1; then
  echo "[Error] Sensitive-arg detector should flag variadic nginx docker opts after an empty first word." >&2
  exit 1
fi
if _run_command_has_sensitive_args status; then
  echo "[Error] Sensitive-arg detector should not flag status." >&2
  exit 1
fi
if _run_command_has_sensitive_args status --foo; then
  echo "[Error] Sensitive-arg detector should not flag unknown flags for empty-spec commands." >&2
  exit 1
fi
if _run_command_has_sensitive_args show-visibility-policy; then
  echo "[Error] Sensitive-arg detector should not flag no-argument commands." >&2
  exit 1
fi
if ! _run_command_has_sensitive_args add-header --req-resp response --header X-Token MIXED_HEADER_SECRET=hidden; then
  echo "[Error] Sensitive-arg detector should flag mixed flag/positional header values." >&2
  exit 1
fi
if _run_command_has_sensitive_args set-hsts off; then
  echo "[Error] Sensitive-arg detector should not flag HSTS off clears." >&2
  exit 1
fi
if _run_command_has_sensitive_args start-nginx --docker-opts ""; then
  echo "[Error] Sensitive-arg detector should not flag empty docker opts clears." >&2
  exit 1
fi
if _run_command_has_sensitive_args update-backend example.com --docker-opts __DOCKER_OPTS_CLEAR__; then
  echo "[Error] Sensitive-arg detector should not flag backend docker opts clear sentinels." >&2
  exit 1
fi
if ! _run_command_has_sensitive_args start-nginx --docker-opts "" --env EMPTY_FLAG_DOCKER_SECRET=hidden; then
  echo "[Error] Sensitive-arg detector should flag split docker opts after an empty flag value." >&2
  exit 1
fi
if _run_command_has_sensitive_args set-nginx-docker-opts ""; then
  echo "[Error] Sensitive-arg detector should not flag empty variadic docker opts clears." >&2
  exit 1
fi
if _run_command_has_sensitive_args start-nginx --unknown-flag nginx:mainline; then
  echo "[Error] Unknown long flags should not shift positional detection into false sensitive matches." >&2
  exit 1
fi

for unexpected in SECRET=top TOKEN=hidden NGINX_SECRET=hidden UNQUOTED_DOCKER_SECRET=hidden EMPTY_FLAG_DOCKER_SECRET=hidden UNKNOWN_SHIFT_SECRET=hidden GLOBAL_SECRET=hidden VARIADIC_SECRET=top EMPTY_FIRST_VARIADIC_SECRET=top "--cpus" HEADER_SECRET=hidden SPLIT_HEADER_SECRET=hidden EMPTY_FLAG_HEADER_SECRET=hidden MIXED_HEADER_SECRET=hidden "max-age=60" POST_BOUNDARY_SECRET=hidden SHIFT_SECRET=hidden "--network [REDACTED]" "--unknown-flag [REDACTED]"; do
  if grep -Fq -- "$unexpected" "$AUDIT_LOG_FILE"; then
    echo "[Error] Audit log leaked redacted operator value: $unexpected" >&2
    cat "$AUDIT_LOG_FILE" >&2
    exit 1
  fi
done
for expected in \
  "add-backend example.com nginx:alpine 80 http 80 selfsigned yes [REDACTED]" \
  "update-backend example.com --docker-opts [REDACTED]" \
  "update-backend example.com --docker-opts __DOCKER_OPTS_CLEAR__" \
  "start-nginx --docker-opts=[REDACTED]" \
  "start-nginx --docker-opts [REDACTED]" \
  "start-nginx --unknown-flag nginx:mainline --docker-opts [REDACTED]" \
  "set-nginx-docker-opts [REDACTED]" \
  "add-header response X-Token [REDACTED]" \
  "add-header --req-resp response --header X-Token --value [REDACTED]" \
  "add-header --req-resp response --header X-Token [REDACTED]" \
  "set-hsts [REDACTED]" \
  "set-hsts off" \
  "set-hsts Off" \
  "set-csp off" \
  "set-csp OFF" \
  "add-backend example.com nginx:alpine 80 http --docker-opts [REDACTED] --no-expose" \
  "add-backend --domain example.com --image nginx:alpine --container-port 80 --protocol http --listen 80 --cert-path selfsigned --ws yes --network mynet --docker-opts [REDACTED]"; do
  if ! grep -Fq -- "$expected" "$AUDIT_LOG_FILE"; then
    echo "[Error] Audit log missing expected redacted context: $expected" >&2
    cat "$AUDIT_LOG_FILE" >&2
    exit 1
  fi
done

echo "[tests] audit_log_docker_opts_visibility.sh: PASS"
