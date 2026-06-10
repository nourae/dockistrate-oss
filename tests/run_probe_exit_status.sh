#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_run_probe_status.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "${TMP_DIR}/tests/lib"

cp "${ROOT_DIR}/tests/run.sh" "${TMP_DIR}/tests/run.sh"

cat >"${TMP_DIR}/dockistrate.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF

cat >"${TMP_DIR}/tests/lib/run_with_timeout.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${1:-}" = "--probe" ]; then
  echo "[tests] Error: fake probe failure" >&2
  exit 2
fi

exit 99
EOF

chmod +x "${TMP_DIR}/dockistrate.sh" "${TMP_DIR}/tests/lib/run_with_timeout.sh"

set +e
(cd "$TMP_DIR" && bash ./tests/run.sh >/dev/null 2>"${TMP_DIR}/run.err")
rc=$?
set -e

if [ "$rc" -ne 2 ]; then
  echo "[Error] Expected tests/run.sh to preserve probe exit status 2, got ${rc}." >&2
  exit 1
fi

if ! grep -Fq "[tests] Error: fake probe failure" "${TMP_DIR}/run.err"; then
  echo "[Error] Expected tests/run.sh to surface the helper probe error output." >&2
  exit 1
fi

echo "[tests] run_probe_exit_status.sh: PASS"
