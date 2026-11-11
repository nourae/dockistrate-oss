#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT_DIR}/tests/lib/run_with_timeout.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_timeout_helper.XXXXXX")"

if ! "$HELPER" --probe >/dev/null 2>&1; then
  echo "[Skip] GNU timeout/gtimeout/gnutimeout not installed; skipping timeout helper regression."
  exit 0
fi

active_helper_pid=""
active_fixture_pid=""

function cleanup() {
  # These process groups belong only to fixtures started by this test.
  if [ -n "$active_fixture_pid" ]; then
    kill -TERM -- "-${active_fixture_pid}" >/dev/null 2>&1 || true
  fi
  if [ -n "$active_helper_pid" ]; then
    kill -TERM "$active_helper_pid" >/dev/null 2>&1 || true
    wait "$active_helper_pid" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

function assert_timeout_alias_resolution() {
  local alias_dir="${TMP_DIR}/alias-bin" candidate version_output real_timeout="" tool rc
  for candidate in timeout gtimeout gnutimeout; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    version_output="$("$candidate" --version 2>/dev/null || true)"
    case "$version_output" in
    *"GNU coreutils"*) real_timeout="$(command -v "$candidate")"; break ;;
    esac
  done
  if [ -z "$real_timeout" ]; then
    echo "[Error] Alias regression could not find the probed GNU timeout backend." >&2
    exit 1
  fi
  mkdir "$alias_dir"
  ln -s "$BASH" "$alias_dir/bash"
  for tool in mktemp cat rm ps sort sleep; do
    ln -s "$(command -v "$tool")" "$alias_dir/$tool"
  done
  # Model distributions where the short names are non-GNU and only the GNU
  # prefixed alias supports the required timeout behavior. No system PATH
  # fallback is available inside this fixture.
  cat >"$alias_dir/timeout" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'timeout (uutils coreutils) 0.10.0\n'
  exit 0
fi
printf 'non-GNU backend was executed\n' >>"$TIMEOUT_ALIAS_LOG"
exit 99
EOF
  cp "$alias_dir/timeout" "$alias_dir/gtimeout"
  cat >"$alias_dir/gnutimeout" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" != --version ]; then
  printf 'gnutimeout\n' >>"$TIMEOUT_ALIAS_LOG"
fi
exec "$REAL_GNU_TIMEOUT" "$@"
EOF
  chmod +x "$alias_dir/timeout" "$alias_dir/gtimeout" "$alias_dir/gnutimeout"
  if ! PATH="$alias_dir" REAL_GNU_TIMEOUT="$real_timeout" TIMEOUT_ALIAS_LOG="${TMP_DIR}/alias.log" \
    "$BASH" "$HELPER" --probe; then
    echo "[Error] GNU gnutimeout alias was not recognized." >&2
    exit 1
  fi
  for rc in 0 7; do
    local actual_status=0
    PATH="$alias_dir" REAL_GNU_TIMEOUT="$real_timeout" TIMEOUT_ALIAS_LOG="${TMP_DIR}/alias.log" \
      "$BASH" "$HELPER" 5 1 alias-exit -- "$BASH" -c 'exit "$1"' alias-command "$rc" \
      >"${TMP_DIR}/alias.stdout" 2>"${TMP_DIR}/alias.stderr" || actual_status=$?
    if [ "$actual_status" -ne "$rc" ]; then
      echo "[Error] gnutimeout alias changed child exit ${rc} to ${actual_status}." >&2
      exit 1
    fi
  done
  printf 'gnutimeout\ngnutimeout\n' >"${TMP_DIR}/alias.expected"
  if ! cmp -s "${TMP_DIR}/alias.expected" "${TMP_DIR}/alias.log"; then
    echo "[Error] Alias execution selected an unexpected timeout backend." >&2
    exit 1
  fi

  cp "$alias_dir/timeout" "$alias_dir/gnutimeout"
  for candidate in non_gnu_alias missing_alias; do
    if [ "$candidate" = missing_alias ]; then rm "$alias_dir/gnutimeout"; fi
    if PATH="$alias_dir" "$BASH" "$HELPER" --probe >"${TMP_DIR}/alias.stdout" 2>"${TMP_DIR}/alias.stderr"; then
      echo "[Error] Probe accepted ${candidate} without a GNU backend." >&2
      exit 1
    else
      rc=$?
    fi
    if [ "$rc" -ne 2 ] || ! grep -Fq 'GNU timeout is required' "${TMP_DIR}/alias.stderr"; then
      echo "[Error] Missing GNU backend changed dependency failure behavior." >&2
      exit 1
    fi
  done
}

assert_timeout_alias_resolution
if [ "${1:-}" = --alias-only ]; then
  echo "[tests] timeout alias resolution: PASS"
  exit 0
fi

success_script="${TMP_DIR}/success.sh"
fail_script="${TMP_DIR}/fail.sh"
exit_124_script="${TMP_DIR}/exit_124.sh"
exit_125_script="${TMP_DIR}/exit_125.sh"
hang_script="${TMP_DIR}/hang.sh"
child_pid_file="${TMP_DIR}/child.pid"
fixture_pid_file="${TMP_DIR}/fixture.pid"
exit_124_err="${TMP_DIR}/exit_124.err"
exit_125_err="${TMP_DIR}/exit_125.err"
hang_err="${TMP_DIR}/hang.err"
exit_env_script="${TMP_DIR}/exit-env.sh"

# Force an ordinary shell exit while the command is running, independently of
# the helper's INT/TERM handlers, to exercise its EXIT cleanup.
cat >"$exit_env_script" <<'EOF'
# shellcheck shell=bash
trap 'exit 77' USR1
EOF

cat >"$success_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF

cat >"$fail_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 7
EOF

cat >"$exit_124_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 124
EOF

cat >"$exit_125_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 125
EOF

cat >"$hang_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${CHILD_PID_FILE:?}"
sleep "${STARTUP_DELAY:-0}"
child_pid=""
function cleanup_child() {
  if [ -n "$child_pid" ]; then
    # Reap the child, but do not signal it: the helper must kill the whole group.
    wait "$child_pid" 2>/dev/null || true
  fi
  exit 0
}
trap cleanup_child TERM INT
sleep 30 &
child_pid="$!"
printf '%s\n' "$$" >"$FIXTURE_PID_FILE"
printf '%s\n' "$child_pid" >"$CHILD_PID_FILE"
wait "$child_pid"
EOF

chmod +x "$success_script" "$fail_script" "$exit_124_script" "$exit_125_script" "$hang_script"

if ! "$HELPER" 5 1 "success-script" -- "$success_script" >/dev/null 2>&1; then
  echo "[Error] Expected success script to pass through exit 0." >&2
  exit 1
fi

if "$HELPER" 5 1 "fail-script" -- "$fail_script" >/dev/null 2>&1; then
  echo "[Error] Expected fail script to return non-zero." >&2
  exit 1
else
  rc=$?
  if [ "$rc" -ne 7 ]; then
    echo "[Error] Expected fail script to preserve exit 7, got ${rc}." >&2
    exit 1
  fi
fi

if "$HELPER" 5 1 "exit-124-script" -- "$exit_124_script" >/dev/null 2>"$exit_124_err"; then
  echo "[Error] Expected exit-124 script to return non-zero." >&2
  exit 1
else
  rc=$?
  if [ "$rc" -ne 124 ]; then
    echo "[Error] Expected exit-124 script to preserve exit 124, got ${rc}." >&2
    exit 1
  fi
fi
if grep -Fq "[tests] Timed out after" "$exit_124_err"; then
  echo "[Error] Exit-124 script should not be labeled as a timeout." >&2
  exit 1
fi

if "$HELPER" 5 1 "exit-125-script" -- "$exit_125_script" >/dev/null 2>"$exit_125_err"; then
  echo "[Error] Expected exit-125 script to return non-zero." >&2
  exit 1
else
  rc=$?
  if [ "$rc" -ne 125 ]; then
    echo "[Error] Expected exit-125 script to preserve exit 125, got ${rc}." >&2
    exit 1
  fi
fi
if grep -Fq "[tests] Timed out after" "$exit_125_err"; then
  echo "[Error] Exit-125 script should not be labeled as a timeout." >&2
  exit 1
fi

start_epoch="$(date '+%s')"
# Exercise startup lasting longer than the old one-second deadline. Keep the
# child-cleanup assertion and the original ten-second overall bound.
if STARTUP_DELAY=1.2 CHILD_PID_FILE="$child_pid_file" FIXTURE_PID_FILE="$fixture_pid_file" \
  "$HELPER" 5 1 "hang-script" -- "$hang_script" >/dev/null 2>"$hang_err"; then
  echo "[Error] Expected hanging script to time out." >&2
  exit 1
else
  rc=$?
  if [ "$rc" -ne 124 ]; then
    echo "[Error] Expected hanging script to return timeout exit 124, got ${rc}." >&2
    exit 1
  fi
fi
if ! grep -Fq "[tests] Timed out after 5s: hang-script" "$hang_err"; then
  echo "[Error] Hanging script should emit an explicit timeout marker." >&2
  exit 1
fi
end_epoch="$(date '+%s')"

if [ ! -s "$child_pid_file" ]; then
  echo "[Error] Hanging script did not record child PID before timeout." >&2
  exit 1
fi
child_pid="$(cat "$child_pid_file")"
if kill -0 "$child_pid" >/dev/null 2>&1; then
  echo "[Error] Timed-out helper left child PID ${child_pid} running." >&2
  exit 1
fi

elapsed=$((end_epoch - start_epoch))
if [ "$elapsed" -lt 5 ] || [ "$elapsed" -ge 10 ]; then
  echo "[Error] Timeout helper did not finish within 5-9 seconds (${elapsed}s)." >&2
  exit 1
fi

function assert_cancellation() {
  local cancel_signal="$1" expected_status="$2"
  local ready_checks=100 rc=0 fixture_pid child_pid
  local child_file="${TMP_DIR}/${cancel_signal}.child.pid"
  local fixture_file="${TMP_DIR}/${cancel_signal}.fixture.pid"
  local error_file="${TMP_DIR}/${cancel_signal}.err"
  local start_epoch end_epoch

  # Job control keeps INT enabled in the helper, matching a foreground runner.
  set -m
  BASH_ENV="$exit_env_script" CHILD_PID_FILE="$child_file" FIXTURE_PID_FILE="$fixture_file" \
    "$HELPER" 30 1 "cancel-${cancel_signal}" -- "$hang_script" >/dev/null 2>"$error_file" &
  active_helper_pid=$!
  set +m
  while [ ! -s "$child_file" ] && [ "$ready_checks" -gt 0 ]; do
    sleep 0.1
    ready_checks=$((ready_checks - 1))
  done
  if [ ! -s "$child_file" ] || [ ! -s "$fixture_file" ]; then
    echo "[Error] ${cancel_signal} fixture did not become ready." >&2
    exit 1
  fi
  child_pid="$(cat "$child_file")"
  fixture_pid="$(cat "$fixture_file")"
  active_fixture_pid="$fixture_pid"

  start_epoch="$(date '+%s')"
  kill -"$cancel_signal" "$active_helper_pid"
  wait "$active_helper_pid" || rc=$?
  active_helper_pid=""
  end_epoch="$(date '+%s')"
  if [ "$rc" -ne "$expected_status" ]; then
    echo "[Error] ${cancel_signal} should return ${expected_status}, got ${rc}." >&2
    exit 1
  fi
  if kill -0 "$fixture_pid" >/dev/null 2>&1 || kill -0 "$child_pid" >/dev/null 2>&1; then
    echo "[Error] ${cancel_signal} left its fixture or child running." >&2
    exit 1
  fi
  active_fixture_pid=""
  if grep -Fq "[tests] Timed out after" "$error_file"; then
    echo "[Error] ${cancel_signal} cancellation should not be labeled as a timeout." >&2
    exit 1
  fi
  if [ "$((end_epoch - start_epoch))" -ge 10 ]; then
    echo "[Error] ${cancel_signal} cancellation did not stop promptly." >&2
    exit 1
  fi
}

assert_cancellation TERM 143
assert_cancellation INT 130
assert_cancellation USR1 77

echo "[tests] run_with_timeout_helper.sh: PASS"
