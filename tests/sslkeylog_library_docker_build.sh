#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/utils/validators.sh
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck source=../lib/nginx/ensure_sslkeylog_library.sh
source "$ROOT_DIR/lib/nginx/ensure_sslkeylog_library.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_sslkeylog_build.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

mock_bin="$tmp_dir/bin"
mkdir -p "$mock_bin"
docker_log="$tmp_dir/docker.log"

cat >"$mock_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s\n' "$*" >>"${DOCKER_STUB_LOG:?}"

if [ "${1:-}" = "image" ] && [ "${2:-}" = "inspect" ]; then
  if [ "${DOCKER_STUB_IMAGE_INSPECT_FAIL:-}" = "true" ]; then
    exit 1
  fi
  printf '%s\n' "${DOCKER_STUB_IMAGE_ID:-sha256:test-image-one}"
  exit 0
fi

if [ "${1:-}" != "run" ]; then
  exit 1
fi
shift || true

out_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
  -v)
    shift
    volume="${1:-}"
    source_path="${volume%%:*}"
    remainder="${volume#*:}"
    dest_path="${remainder%%:*}"
    if [ "$dest_path" = "/out" ]; then
      out_dir="$source_path"
    fi
    ;;
  esac
  shift || true
done

if [ "${DOCKER_STUB_FAIL:-}" = "true" ]; then
  exit 1
fi

[ -n "$out_dir" ] || exit 1
mkdir -p "$out_dir"
printf '%s\n' "mock shared object" >"${out_dir}/sslkeylogfile.so"
if [ -n "${DOCKER_STUB_MUTATE_SOURCE:-}" ]; then
  printf '%s\n' 'int changed_during_build;' >>"$DOCKER_STUB_MUTATE_SOURCE"
fi
exit 0
EOF
chmod +x "$mock_bin/docker"

SSLKEYLOG_LIB_SOURCE_DIR="$tmp_dir/src"
SSLKEYLOG_LIB_SOURCE_FILE="$SSLKEYLOG_LIB_SOURCE_DIR/sslkeylogfile.c"
SSLKEYLOG_LIB_BUILD_DIR="$tmp_dir/out"
SSLKEYLOG_LIB_BUILD_FILE="$SSLKEYLOG_LIB_BUILD_DIR/sslkeylogfile.so"
SSLKEYLOG_LIB_BUILD_META_FILE="$SSLKEYLOG_LIB_BUILD_DIR/sslkeylogfile.meta"
mkdir -p "$SSLKEYLOG_LIB_SOURCE_DIR"
printf '%s\n' 'int unused;' >"$SSLKEYLOG_LIB_SOURCE_FILE"

PATH="$mock_bin:$PATH" DOCKER_STUB_LOG="$docker_log" DOCKER_STUB_IMAGE_ID="sha256:test-image-one" \
  ensure_sslkeylog_library "nginx:test"

if [ ! -s "$SSLKEYLOG_LIB_BUILD_FILE" ]; then
  echo "[Error] ensure_sslkeylog_library did not produce the expected shared object." >&2
  exit 1
fi

if ! grep -Fq -- "--entrypoint sh" "$docker_log"; then
  echo "[Error] helper build should force sh as the Docker entrypoint." >&2
  cat "$docker_log" >&2
  exit 1
fi

if ! grep -Fq -- "nginx:test -c" "$docker_log"; then
  echo "[Error] helper build should use the configured nginx image." >&2
  cat "$docker_log" >&2
  exit 1
fi

if grep -Fq -- "nginx:test sh -c" "$docker_log"; then
  echo "[Error] helper build should not rely on the image entrypoint to run sh -c." >&2
  cat "$docker_log" >&2
  exit 1
fi

if ! grep -Fxq "nginx:test|sha256:test-image-one" "$SSLKEYLOG_LIB_BUILD_META_FILE"; then
  echo "[Error] helper build metadata should record the image ref and image ID." >&2
  cat "$SSLKEYLOG_LIB_BUILD_META_FILE" >&2
  exit 1
fi
source_fingerprint="$(_sslkeylog_source_fingerprint)"
if ! grep -Fxq "source=${source_fingerprint}" "$SSLKEYLOG_LIB_BUILD_META_FILE"; then
  echo "[Error] helper build metadata should record the exact source SHA-256." >&2
  exit 1
fi

touch -t 209901010000 "$SSLKEYLOG_LIB_BUILD_FILE"
: >"$docker_log"
PATH="$mock_bin:$PATH" DOCKER_STUB_LOG="$docker_log" DOCKER_STUB_IMAGE_ID="sha256:test-image-one" \
  ensure_sslkeylog_library "nginx:test"
if grep -q '^run ' "$docker_log"; then
  echo "[Error] existing up-to-date helper should skip Docker rebuild." >&2
  cat "$docker_log" >&2
  exit 1
fi

: >"$docker_log"
PATH="$mock_bin:$PATH" DOCKER_STUB_LOG="$docker_log" DOCKER_STUB_IMAGE_ID="sha256:test-image-two" \
  ensure_sslkeylog_library "nginx:test"
if ! grep -q '^run ' "$docker_log"; then
  echo "[Error] changed image identity should force Docker rebuild." >&2
  cat "$docker_log" >&2
  exit 1
fi
if ! grep -Fxq "nginx:test|sha256:test-image-two" "$SSLKEYLOG_LIB_BUILD_META_FILE"; then
  echo "[Error] helper build metadata should update after image identity changes." >&2
  cat "$SSLKEYLOG_LIB_BUILD_META_FILE" >&2
  exit 1
fi

# File timestamps cannot identify the loaded implementation: checkout, restores,
# and copied artifacts can retain or backdate them independently of the content.
touch -t 200101010000 "$SSLKEYLOG_LIB_SOURCE_FILE"
: >"$docker_log"
PATH="$mock_bin:$PATH" DOCKER_STUB_LOG="$docker_log" DOCKER_STUB_IMAGE_ID="sha256:test-image-two" \
  ensure_sslkeylog_library "nginx:test"
if grep -q '^run ' "$docker_log"; then
  echo "[Error] unchanged source content should remain cached after an mtime-only change." >&2
  exit 1
fi
printf '%s\n' 'int updated_source;' >"$SSLKEYLOG_LIB_SOURCE_FILE"
touch -t 200101010000 "$SSLKEYLOG_LIB_SOURCE_FILE"
: >"$docker_log"
PATH="$mock_bin:$PATH" DOCKER_STUB_LOG="$docker_log" DOCKER_STUB_IMAGE_ID="sha256:test-image-two" \
  ensure_sslkeylog_library "nginx:test"
if ! grep -q '^run ' "$docker_log"; then
  echo "[Error] changed source content with a preserved old mtime must force a rebuild." >&2
  exit 1
fi
source_fingerprint="$(_sslkeylog_source_fingerprint)"
if ! grep -Fxq "source=${source_fingerprint}" "$SSLKEYLOG_LIB_BUILD_META_FILE"; then
  echo "[Error] rebuilt helper metadata must identify the updated source content." >&2
  exit 1
fi

printf '%s\n' 'nginx:test|sha256:test-image-two' >"$SSLKEYLOG_LIB_BUILD_META_FILE"
: >"$docker_log"
PATH="$mock_bin:$PATH" DOCKER_STUB_LOG="$docker_log" DOCKER_STUB_IMAGE_ID="sha256:test-image-two" \
  ensure_sslkeylog_library "nginx:test"
if ! grep -q '^run ' "$docker_log"; then
  echo "[Error] cached helpers without source identity must be rebuilt." >&2
  exit 1
fi

printf '%s\n' 'int source_before_build;' >"$SSLKEYLOG_LIB_SOURCE_FILE"
if PATH="$mock_bin:$PATH" DOCKER_STUB_LOG="$docker_log" DOCKER_STUB_IMAGE_ID="sha256:test-image-two" \
  DOCKER_STUB_MUTATE_SOURCE="$SSLKEYLOG_LIB_SOURCE_FILE" ensure_sslkeylog_library "nginx:test" >"$tmp_dir/mutation.out" 2>&1; then
  echo "[Error] a build using concurrently changed source must fail." >&2
  exit 1
fi
if [ -e "$SSLKEYLOG_LIB_BUILD_META_FILE" ]; then
  echo "[Error] failed source-race builds must not leave trusted cache metadata." >&2
  exit 1
fi
: >"$docker_log"
PATH="$mock_bin:$PATH" DOCKER_STUB_LOG="$docker_log" DOCKER_STUB_IMAGE_ID="sha256:test-image-two" \
  ensure_sslkeylog_library "nginx:test"
if ! grep -q '^run ' "$docker_log"; then
  echo "[Error] retrying after a source-race failure must rebuild the helper." >&2
  exit 1
fi

rm -f "$SSLKEYLOG_LIB_BUILD_FILE"
if PATH="$mock_bin:$PATH" DOCKER_STUB_LOG="$docker_log" DOCKER_STUB_IMAGE_ID="sha256:test-image-two" \
  DOCKER_STUB_FAIL=true ensure_sslkeylog_library "nginx:test" 2>/dev/null; then
  echo "[Error] helper build should fail when Docker build command fails." >&2
  exit 1
fi
if [ -e "$SSLKEYLOG_LIB_BUILD_META_FILE" ]; then
  echo "[Error] failed Docker builds must invalidate prior trusted cache metadata." >&2
  exit 1
fi

echo "TLS keylog helper Docker build checks passed."
