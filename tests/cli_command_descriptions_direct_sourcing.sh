#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  # shellcheck source=../lib/cli/command_descriptions.sh
  source "$ROOT_DIR/lib/cli/command_descriptions.sh"
  if ! declare -F _set_command_description >/dev/null 2>&1; then
    echo "_set_command_description should be available after directly sourcing command_descriptions.sh" >&2
    exit 1
  fi

  # shellcheck source=../lib/cli/command_description.sh
  source "$ROOT_DIR/lib/cli/command_description.sh"
  description="$(command_description start-nginx)"
  expected="Start or recreate the Nginx proxy container (refreshes backend IPs)"
  if [ "$description" != "$expected" ]; then
    echo "Unexpected command description after direct sourcing: $description" >&2
    exit 1
  fi
'

ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  # shellcheck source=../lib/cli/command_descriptions.sh
  source "$ROOT_DIR/lib/cli/command_descriptions.sh"
  # shellcheck source=../lib/cli.sh
  source "$ROOT_DIR/lib/cli.sh"

  if ! declare -F command_description >/dev/null 2>&1; then
    echo "command_description should be available after sourcing lib/cli.sh" >&2
    exit 1
  fi

  description="$(command_description start-nginx)"
  expected="Start or recreate the Nginx proxy container (refreshes backend IPs)"
  if [ "$description" != "$expected" ]; then
    echo "Unexpected command description after mixed-source load order: $description" >&2
    exit 1
  fi
'

echo "CLI command description direct sourcing checks passed."
