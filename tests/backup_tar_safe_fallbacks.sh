#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/backups/common.sh
source "$ROOT_DIR/lib/backups/common.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_tar_fallback.XXXXXX")"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

MOCK_BIN="$TMP_ROOT/bin"
mkdir -p "$MOCK_BIN"
cat >"$MOCK_BIN/tar" <<'EOF_TAR'
#!/usr/bin/env bash
set -Eeuo pipefail

printf '%s\n' "$*" >>"$TAR_STUB_LOG"

for arg in "$@"; do
  if [ "$arg" = "--version" ]; then
    printf '%s\n' "${TAR_STUB_VERSION:-unknown tar}"
    exit 0
  fi
done

case " $* " in
*" -tzf "*)
  printf '%s\n' 'backup_dir/' 'backup_dir/config/file.txt'
  exit 0
  ;;
*" -tzvf "*)
  printf '%s\n' \
    'drwxr-xr-x  0 user group        0 Jan  1 00:00 backup_dir/' \
    '-rw-r--r--  0 user group        2 Jan  1 00:00 backup_dir/config/file.txt'
  exit 0
  ;;
esac

target_dir=""
previous=""
for arg in "$@"; do
  if [ "$previous" = "-C" ]; then
    target_dir="$arg"
    break
  fi
  previous="$arg"
done
[ -n "$target_dir" ] || exit 1

case "${TAR_STUB_MODE:-}" in
gnu)
  has_no_owner=false
  has_no_permissions=false
  for arg in "$@"; do
    [ "$arg" = "--no-same-owner" ] && has_no_owner=true
    [ "$arg" = "--no-same-permissions" ] && has_no_permissions=true
  done
  if [ "$has_no_owner" = true ] && [ "$has_no_permissions" = true ]; then
    mkdir -p "$target_dir/backup_dir/config"
    printf 'ok\n' >"$target_dir/backup_dir/config/file.txt"
    exit 0
  fi
  exit 1
  ;;
bsd)
  for arg in "$@"; do
    if [ "$arg" = "-xozf" ]; then
      mkdir -p "$target_dir/backup_dir/config"
      printf 'ok\n' >"$target_dir/backup_dir/config/file.txt"
      exit 0
    fi
  done
  case " $* " in
  *" -xozf"*)
    mkdir -p "$target_dir/backup_dir/config"
    printf 'ok\n' >"$target_dir/backup_dir/config/file.txt"
    exit 0
    ;;
  esac
  exit 1
  ;;
*)
  exit 1
  ;;
esac
EOF_TAR
chmod +x "$MOCK_BIN/tar"

archive="$TMP_ROOT/archive.tar.gz"
touch "$archive"

run_success_case() {
  local mode="$1" version="$2" label="$3" dest=""
  dest="$TMP_ROOT/${label}_dest"
  TAR_STUB_MODE="$mode" TAR_STUB_VERSION="$version" TAR_STUB_LOG="$TMP_ROOT/${label}.log" \
    PATH="$MOCK_BIN:$PATH" _safe_extract_tar "$archive" "$dest"
  if [ ! -f "$dest/backup_dir/config/file.txt" ]; then
    echo "[Error] ${label} tar extraction did not create expected file." >&2
    exit 1
  fi
}

run_success_case gnu 'tar (GNU tar) 1.34' gnu
if ! grep -Fq -- '--no-same-owner' "$TMP_ROOT/gnu.log" ||
  ! grep -Fq -- '--no-same-permissions' "$TMP_ROOT/gnu.log"; then
  echo "[Error] GNU tar extraction did not use ownership/permission safety flags." >&2
  exit 1
fi

run_success_case bsd 'bsdtar 3.5.3 - libarchive 3.5.3' bsd
if ! grep -Fq -- '-xozf' "$TMP_ROOT/bsd.log"; then
  echo "[Error] BSD tar extraction did not use -o safety mode." >&2
  exit 1
fi

set +e
TAR_STUB_MODE=unknown TAR_STUB_VERSION='mystery tar 1.0' TAR_STUB_LOG="$TMP_ROOT/unknown.log" \
  PATH="$MOCK_BIN:$PATH" _safe_extract_tar "$archive" "$TMP_ROOT/unknown_dest" >/dev/null 2>&1
unknown_status=$?
set -e
if [ "$unknown_status" -eq 0 ]; then
  echo "[Error] Unknown tar implementation should fail closed." >&2
  exit 1
fi

echo "[tests] backup_tar_safe_fallbacks.sh: PASS"
