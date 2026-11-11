#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/cli/arg_metadata.sh
source "$ROOT_DIR/lib/cli/arg_metadata.sh"
# shellcheck source=../lib/utils/operator_visibility.sh
source "$ROOT_DIR/lib/utils/operator_visibility.sh"
# shellcheck source=../lib/cli/command_visibility.sh
source "$ROOT_DIR/lib/cli/command_visibility.sh"
# shellcheck source=../lib/cli/review_command.sh
source "$ROOT_DIR/lib/cli/review_command.sh"
# shellcheck source=../lib/cli/prompt_args_handlers_postprocess.sh
source "$ROOT_DIR/lib/cli/prompt_args_handlers_postprocess.sh"

VISIBILITY_POLICY=full
DEFAULT_VISIBILITY_POLICY=full
NGINX_IMAGE=nginx:latest
NGINX_DOCKER_OPTS='--memory 1g'
summary=''

function expect_row() {
  if [[ "$summary" != *"$1"* ]]; then
    printf '[Error] Missing review row: %s\n%s\n' "$1" "$summary" >&2
    exit 1
  fi
}

function summarize_collected() {
  local command="$1"
  shift
  PROMPT_ARGS_COLLECTED=("$@")
  prompt_args_postprocess "$command"
  if [ "${#PROMPT_ARGS_COLLECTED[@]}" -gt 0 ]; then
    summary="$(_review_command_format_arg_summary "$command" "${PROMPT_ARGS_COLLECTED[@]}")"
  else
    summary="$(_review_command_format_arg_summary "$command")"
  fi
  if [[ "$summary" == *'Argument '* ]] || [[ "$summary" == *'Unrecognized argument'* ]]; then
    printf '[Error] Collected inputs have no semantic review: %s\n' "$summary" >&2
    exit 1
  fi
}

summarize_collected add-path-option example.com 80 /api on off demo exact 50 8080 strip-prefix 'API reason' config
for row in 'Domain: example.com' 'Listen port: 80' 'Path prefix: /api' 'WebSocket: on' \
  'Redirect: off' 'Header set: demo' 'Path match type: exact' 'Path priority: 50' \
  'Upstream target: 8080' 'Path rewrite: strip-prefix' 'Reason: API reason' 'Source location: config'; do
  expect_row "$row"
done
summarize_collected add-path-option example.com 80 /api inherit inherit none prefix 100 none none - auto
[ "${#PROMPT_ARGS_COLLECTED[@]}" -eq 3 ]
expect_row 'Path prefix: /api'

summarize_collected update-path-option example.com 80 /api /service 8081 on inherit none exact 50 8080 strip-prefix 'Service reason' auto
for row in 'Current listen port: 80' 'Current path prefix: /api' 'New path prefix: /service' \
  'New listen port: 8081' 'WebSocket: on' 'Redirect: inherit' 'Header set: none' \
  'Path match type: exact' 'Path priority: 50' 'Upstream target: 8080' \
  'Path rewrite: strip-prefix' 'Reason: Service reason' 'Source location: auto'; do
  expect_row "$row"
done

summarize_collected update-security-rule 7 --domain example.com --action block --code - \
  --reason 'Example reason' --loc config --count 2 header User-Agent contains OtherBot method - equals POST --mode or
for row in 'ID: 7' 'Domain: example.com' 'Action: block' 'Status code: Inherited default' \
  'Reason: Example reason' 'Source location: config' 'Condition count: 2' \
  'Condition 1 — Source: header' 'Condition 1 — Name: User-Agent' 'Condition 1 — Test: contains' \
  'Condition 1 — Value: OtherBot' 'Condition 2 — Source: method' 'Condition 2 — Name: -' \
  'Condition 2 — Test: equals' 'Condition 2 — Value: POST' 'Condition combination: or'; do
  expect_row "$row"
done
[ "${PROMPT_ARGS_COLLECTED[8]}" = 'Example reason' ]
summarize_collected update-security-rule 1 --code 404
expect_row 'Status code: 404'

summarize_collected start-nginx __DEFAULT__ ''
expect_row '(none)'
[ "${#PROMPT_ARGS_COLLECTED[@]}" -eq 0 ]
summarize_collected start-nginx mainline '--memory 2g'
expect_row 'nginx image: nginx:mainline'
expect_row 'Extra Docker run options: --memory 2g'
[ "$(format_cli_equivalent start-nginx "${PROMPT_ARGS_COLLECTED[@]}")" = "./dockistrate.sh start-nginx --nginx-image nginx:mainline --docker-opts '--memory 2g'" ]
summarize_collected start-nginx __DEFAULT__ __NGINX_DOCKER_OPTS_CLEAR__
expect_row 'Extra Docker run options: (clear)'
[ "${#PROMPT_ARGS_COLLECTED[@]}" -eq 2 ]
[ "${PROMPT_ARGS_COLLECTED[0]}" = --docker-opts ]
[ -z "${PROMPT_ARGS_COLLECTED[1]}" ]
[ "$(format_cli_equivalent start-nginx "${PROMPT_ARGS_COLLECTED[@]}")" = "./dockistrate.sh start-nginx --docker-opts ''" ]

VISIBILITY_POLICY=redacted
summarize_collected start-nginx mainline '--env SECRET=hidden'
expect_row 'nginx image: nginx:mainline'
expect_row 'Extra Docker run options: [REDACTED]'
[[ "$summary" != *SECRET* ]]
[[ "$(format_cli_equivalent start-nginx "${PROMPT_ARGS_COLLECTED[@]}")" != *SECRET* ]]
[ "${PROMPT_ARGS_COLLECTED[3]}" = '--env SECRET=hidden' ]
VISIBILITY_POLICY=full

for scope in backend all; do
  summarize_collected uninstall-all "$scope"
  expect_row "Uninstall scope: $scope"
  [ "${PROMPT_ARGS_COLLECTED[0]}" = --scope ]
  [ "${PROMPT_ARGS_COLLECTED[1]}" = "$scope" ]
done

for scope in global stream-global backend stream-backend port stream-port path; do
  args=("$scope")
  case "$scope" in
  backend | stream-backend) args+=(example.com) ;;
  port | stream-port) args+=(example.com 80) ;;
  path) args+=(example.com 80 /api) ;;
  esac
  args+=(client_max_body_size)
  summarize_collected remove-nginx-directive "${args[@]}"
  expect_row "Directive scope: $scope"
  expect_row 'Directive name: client_max_body_size'
  case "$scope" in
  global | stream-global) [[ "$summary" != *'Domain:'* ]] ;;
  *) expect_row 'Domain: example.com' ;;
  esac
  if [ "$scope" = path ]; then expect_row 'Path prefix: /api'; fi
done

summarize_collected update-path-option example.com 80 /api /new '' '' '' '' '' '' '' '' $'line1\nline2' ''
expect_row 'Reason: line1\nline2'

echo '[tests] review_option_summaries.sh: PASS'
