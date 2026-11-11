#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_keylog_runtime.XXXXXX")"
# The production helper deliberately rejects symlinked ancestor directories.
tmp_dir="$(cd -P "$tmp_dir" && pwd -P)"
trap 'chmod 700 "$tmp_dir"/*-private 2>/dev/null || true; rm -rf "$tmp_dir"' EXIT
compiler="${CC:-cc}"
fixtures="$ROOT_DIR/tests/fixtures"

function fail() {
  echo "[Error] $*" >&2
  exit 1
}

command -v "$compiler" >/dev/null 2>&1 || fail "TLS keylog runtime tests require a C compiler (CC or cc)."
shared_flags=(-shared -fPIC)
loader_flags=(-ldl -pthread)
suffix=so
if [ "$(uname -s)" = Darwin ]; then
  shared_flags=(-dynamiclib)
  loader_flags=(-pthread)
  suffix=dylib
fi
helper="$tmp_dir/sslkeylogfile.$suffix"
mock="$tmp_dir/libsslmock.$suffix"
"$compiler" "${shared_flags[@]}" -O2 -Wall -Wextra -Werror \
  -o "$helper" "$ROOT_DIR/sslkeyloglib/sslkeylogfile.c" "${loader_flags[@]}"
if [ "$suffix" = dylib ]; then
  "$compiler" "${shared_flags[@]}" -Wall -Wextra -Werror -install_name "$mock" \
    -o "$mock" "$fixtures/sslkeylog_mock.c"
else
  "$compiler" "${shared_flags[@]}" -Wall -Wextra -Werror \
    -o "$mock" "$fixtures/sslkeylog_mock.c"
fi
"$compiler" -DKEYLOG_RUNTIME_MOCK -Wall -Wextra -Werror -o "$tmp_dir/mock-runtime" \
  "$fixtures/sslkeylog_runtime.c" "$mock" "-Wl,-rpath,$tmp_dir" "${loader_flags[@]}"

function check_records() {
  local output="$1" logfile="$2"
  [ -s "$logfile" ] || fail "No keylog records were written: $logfile"
  awk '
    NR == FNR {
      if ($1 == "HANDSHAKE") { expected[tolower($4)] = $3; handshakes++ }
      next
    }
    /^#/ { next }
    {
      random = tolower($2)
      if (NF != 3 || length(random) != 64 || random !~ /^[0-9a-f]+$/ ||
          $3 !~ /^[0-9a-fA-F]+$/ || (length($3) != 64 && length($3) != 96)) { bad = 1; next }
      if (!(random in expected)) { bad = 1; next }
      if (expected[random] == "TLSv1.2" && ($1 != "CLIENT_RANDOM" || length($3) != 96)) { bad = 1 }
      if (expected[random] == "TLSv1.3" &&
          $1 !~ /^(CLIENT|SERVER)_HANDSHAKE_TRAFFIC_SECRET$|^(CLIENT|SERVER)_TRAFFIC_SECRET_0$|^EXPORTER_SECRET$/) { bad = 1 }
      if (++records[random SUBSEP $1] != 1) { bad = 1 }
      counts[random]++
    }
    END {
      if (!handshakes) { bad = 1 }
      for (random in expected) {
        if (counts[random] != (expected[random] == "TLSv1.2" ? 1 : 5)) { bad = 1 }
      }
      exit bad ? 1 : 0
    }
  ' "$output" "$logfile" || fail "Malformed, missing, duplicate, or interleaved keylog records: $logfile"
}

function run_harness() {
  local executable="$1" version="$2" scenario="$3" logfile="$4" output="$5"
  LIBSSL_SSLKEYLOGFILE="$logfile" SSLKEYLOGFILE="" \
    "$executable" "$helper" "$version" "$scenario" "$logfile" >"$output" 2>"$output.err" || {
    cat "$output.err" >&2
    fail "TLS keylog runtime failed: $executable TLS1.$version $scenario"
  }
}

function check_positive_cases() {
  local executable="$1" label="$2" version logfile output directory
  for version in 12 13; do
    logfile="$tmp_dir/$label-$version.keys"
    output="$tmp_dir/$label-$version.out"
    run_harness "$executable" "$version" handshake "$logfile" "$output"
    check_records "$output" "$logfile"
    [ ! -s "$output.err" ] || fail "Unexpected diagnostic during successful handshakes: $(cat "$output.err")"
    # A second master opening an existing log must preserve the first records.
    run_harness "$executable" "$version" handshake "$logfile" "$output.second"
    cat "$output.second" >>"$output"
    check_records "$output" "$logfile"
    directory="$tmp_dir/$label-$version-private"
    mkdir -m 700 "$directory"
    logfile="$directory/sslkeys.log"
    : >"$logfile"
    chmod 600 "$logfile"
    output="$tmp_dir/$label-$version-fork.out"
    run_harness "$executable" "$version" fork "$logfile" "$output"
    check_records "$output" "$logfile"
    grep -q '^WORKERS ' "$output" || fail "Fork/privilege regression did not run."
    # POSIX ls verifies private modes without GNU/BSD stat differences.
    [ "$(LC_ALL=C ls -ld "$directory" | awk '{print substr($1, 1, 10)}')" = drwx------ ] || fail "Private log directory permissions changed."
    [ "$(LC_ALL=C ls -l "$logfile" | awk '{print substr($1, 1, 10)}')" = -rw------- ] || fail "Private log file permissions changed."
  done
  echo "TLS keylog $label: TLS1.2/TLS1.3 records, multiple contexts, callback chaining and fork permissions passed."
}

function check_rejected_path() {
  local label="$1" path="$2" executable="${3:-$tmp_dir/mock-runtime}" version output
  for version in 12 13; do
    output="$tmp_dir/reject-$label-$version.out"
    run_harness "$executable" "$version" handshake "$path" "$output"
    [ "$(grep -c 'TLS keylog helper disabled:' "$output.err")" = 1 ] || fail "Unsafe $label path should emit one diagnostic."
  done
}

check_positive_cases "$tmp_dir/mock-runtime" "ABI-runtime"

sentinel="$tmp_dir/sentinel"
printf 'untouched\n' >"$sentinel"
ln -s "$sentinel" "$tmp_dir/symlink.keys"
check_rejected_path symlink "$tmp_dir/symlink.keys"
ln "$sentinel" "$tmp_dir/hardlink.keys"
check_rejected_path hardlink "$tmp_dir/hardlink.keys"
[ "$(cat "$sentinel")" = untouched ] || fail "Unsafe keylog endpoint changed its target."
mkdir "$tmp_dir/real-directory"
ln -s "$tmp_dir/real-directory" "$tmp_dir/linked-directory"
check_rejected_path ancestor-symlink "$tmp_dir/linked-directory/sslkeys.log"
[ ! -e "$tmp_dir/real-directory/sslkeys.log" ] || fail "Helper followed a symlinked ancestor."
mkdir "$tmp_dir/directory.keys"
check_rejected_path directory "$tmp_dir/directory.keys"
mkfifo "$tmp_dir/fifo.keys"
check_rejected_path fifo "$tmp_dir/fifo.keys"

for version in 12 13; do
  output="$tmp_dir/disabled-$version.out"
  run_harness "$tmp_dir/mock-runtime" "$version" handshake "" "$output"
  [ "$(grep -c 'TLS keylog helper disabled:' "$output.err")" = 1 ] || fail "Disabled logging should emit one diagnostic."
  fallback="$tmp_dir/fallback-$version.keys"
  LIBSSL_SSLKEYLOGFILE="" SSLKEYLOGFILE="$fallback" \
    "$tmp_dir/mock-runtime" "$helper" "$version" handshake "$fallback" >"$output" 2>"$output.err"
  check_records "$output" "$fallback"
  primary="$tmp_dir/primary-$version.keys"
  ignored="$tmp_dir/ignored-$version.keys"
  LIBSSL_SSLKEYLOGFILE="$primary" SSLKEYLOGFILE="$ignored" \
    "$tmp_dir/mock-runtime" "$helper" "$version" handshake "$primary" >"$output" 2>"$output.err"
  check_records "$output" "$primary"
  [ ! -e "$ignored" ] || fail "SSLKEYLOGFILE overrode the explicit helper path."
done
echo "TLS keylog ABI runtime: disabled logging, environment precedence and unsafe endpoints passed."

# Real handshakes supplement the mandatory headerless ABI/permission tests when
# development files are installed. Docker end-to-end checks cover production TLS.
openssl_flags=(-lssl -lcrypto)
if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists openssl; then
  read -r -a openssl_flags <<<"$(pkg-config --cflags --libs openssl)"
elif command -v brew >/dev/null 2>&1; then
  openssl_prefix="$(brew --prefix openssl@3 2>/dev/null || true)"
  if [ -n "$openssl_prefix" ] && [ -d "$openssl_prefix/include/openssl" ]; then
    openssl_flags=("-I$openssl_prefix/include" "-L$openssl_prefix/lib" "-Wl,-rpath,$openssl_prefix/lib" -lssl -lcrypto)
  fi
fi
cat >"$tmp_dir/openssl-probe.c" <<'EOF'
#include <openssl/ssl.h>
#if !defined(TLS1_3_VERSION) || OPENSSL_VERSION_NUMBER < 0x10101000L
#error OpenSSL 1.1.1 or newer is required for real TLS keylog runtime tests
#endif
int main(void) {
  SSL_CTX *ctx = SSL_CTX_new(TLS_method());
  SSL_CTX_set_keylog_callback(ctx, 0);
  SSL_CTX_free(ctx);
  return 0;
}
EOF
if "$compiler" -o "$tmp_dir/openssl-probe" "$tmp_dir/openssl-probe.c" "${openssl_flags[@]}" >"$tmp_dir/probe.out" 2>&1; then
  "$compiler" -Wall -Wextra -Werror -o "$tmp_dir/openssl-runtime" "$fixtures/sslkeylog_runtime.c" \
    "${openssl_flags[@]}" "${loader_flags[@]}"
  check_positive_cases "$tmp_dir/openssl-runtime" "OpenSSL-handshakes"
  check_rejected_path real-symlink "$tmp_dir/symlink.keys" "$tmp_dir/openssl-runtime"
  for version in 12 13; do
    run_harness "$tmp_dir/openssl-runtime" "$version" handshake "" "$tmp_dir/real-disabled-$version.out"
  done
  [ "$(cat "$sentinel")" = untouched ] || fail "Real TLS handshakes changed an unsafe log target."
else
  echo "[Info] Real OpenSSL handshake tests unavailable: development headers/libraries for OpenSSL >=1.1.1 are not installed; mandatory ABI runtime tests passed."
fi
