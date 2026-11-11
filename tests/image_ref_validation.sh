#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"

valid_refs=(
  "nginx"
  "nginx:1.25"
  "library/nginx:1.25-alpine"
  "registry.example.com/team/my__image--worker:Tag_1.0"
  "REGISTRY.EXAMPLE.COM:5000/team/repo:tag"
  "[2001:db8::1]:5000/team/repo:tag"
  "[::1]/repo"
  "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  "localhost:5000/repo"
  "registry.example.com:5000/org/repo:tag"
  "repo@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  "repo:tag@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  "registry.example.com:5000/repo@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
)

for ref in "${valid_refs[@]}"; do
  if ! is_valid_image_ref "$ref"; then
    printf 'Expected valid image ref: %s\n' "$ref" >&2
    exit 1
  fi
done

invalid_refs=(
  ""
  "-p80:80"
  "--privileged"
  "-it"
  "repo name"
  $'library/nginx\n--privileged'
  $'library/nginx\n'
  $'library/nginx\r'
  $'library/nginx\toption'
  "repo;command"
  "repo\$(command)"
  "repo___name"
  "repo..name"
  "[::1]:port/repo"
  "[::1]/BadUpper"
  "BadUpper/Repo"
  "repo//name"
  "repo@sha256:xyz"
  "registry:port/repo"
  "repo:tag:again"
)

for ref in "${invalid_refs[@]}"; do
  if is_valid_image_ref "$ref"; then
    printf 'Expected invalid image ref: %s\n' "$ref" >&2
    exit 1
  fi
done

printf 'Image reference validation checks passed.\n'
