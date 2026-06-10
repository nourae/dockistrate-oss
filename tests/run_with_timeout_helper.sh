#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT_DIR}/tests/lib/run_with_timeout.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_timeout_helper.XXXXXX")"

if ! "$HELPER" --probe >/dev/null 2>&1; then
  echo "[Skip] GNU timeout/gtimeout not installed; skipping timeout helper regression."
  exit 0
fi

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

success_script="${TMP_DIR}/success.sh"
fail_script="${TMP_DIR}/fail.sh"
exit_124_script="${TMP_DIR}/exit_124.sh"
hang_script="${TMP_DIR}/hang.sh"
child_pid_file="${TMP_DIR}/child.pid"
exit_124_err="${TMP_DIR}/exit_124.err"
hang_err="${TMP_DIR}/hang.err"

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

cat >"$hang_script" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${CHILD_PID_FILE:?}"
sleep 30 &
child_pid="$!"
printf '%s\n' "$child_pid" >"$CHILD_PID_FILE"
wait "$child_pid"
EOF

chmod +x "$success_script" "$fail_script" "$exit_124_script" "$hang_script"

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

start_epoch="$(date '+%s')"
if CHILD_PID_FILE="$child_pid_file" "$HELPER" 1 1 "hang-script" -- "$hang_script" >/dev/null 2>"$hang_err"; then
  echo "[Error] Expected hanging script to time out." >&2
  exit 1
else
  rc=$?
  if [ "$rc" -ne 124 ]; then
    echo "[Error] Expected hanging script to return timeout exit 124, got ${rc}." >&2
    exit 1
  fi
fi
if ! grep -Fq "[tests] Timed out after 1s: hang-script" "$hang_err"; then
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
if [ "$elapsed" -ge 10 ]; then
  echo "[Error] Timeout helper took too long to fail (${elapsed}s)." >&2
  exit 1
fi

echo "[tests] run_with_timeout_helper.sh: PASS"
