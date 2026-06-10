#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failed=0
use_git_index=false

if command -v git >/dev/null 2>&1 && git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  use_git_index=true
else
  echo "[Warn] Git index unavailable; falling back to filesystem checks for lib shebang policy." >&2
fi

function _iter_lib_shell_files() {
  if [ "$use_git_index" = true ]; then
    git -C "$ROOT_DIR" ls-files -- 'lib/*.sh' 'lib/**/*.sh'
    return
  fi

  local abs_path
  local rel_path
  find "$ROOT_DIR/lib" -type f -name '*.sh' | LC_ALL=C sort | while IFS= read -r abs_path || [ -n "$abs_path" ]; do
    [ -n "$abs_path" ] || continue
    rel_path="${abs_path#${ROOT_DIR}/}"
    printf '%s\n' "$rel_path"
  done
}

while IFS= read -r rel_path || [ -n "$rel_path" ]; do
  [ -n "$rel_path" ] || continue
  file_path="${ROOT_DIR}/${rel_path}"
  mode=""
  if [ "$use_git_index" = true ]; then
    mode="$(git -C "$ROOT_DIR" ls-files --stage -- "$rel_path" | awk '{print $1}')"
  fi

  if [ ! -f "$file_path" ]; then
    echo "[Error] Missing file: ${rel_path}" >&2
    failed=1
    continue
  fi

  if [ -z "$mode" ]; then
    if [ -x "$file_path" ]; then
      mode="100755"
    else
      mode="100644"
    fi
    if [ "$use_git_index" = true ]; then
      echo "[Warn] ${rel_path}: git mode unavailable; using filesystem executability fallback." >&2
    fi
  fi

  first_line="$(head -n 1 "$file_path" || true)"
  if [ "$mode" = "100755" ]; then
    if [ "$first_line" != "#!/usr/bin/env bash" ]; then
      echo "[Error] ${rel_path} is executable and must start with '#!/usr/bin/env bash'." >&2
      failed=1
    fi
    continue
  fi

  if [ "$first_line" != "# shellcheck shell=bash" ]; then
    echo "[Error] ${rel_path} is sourced and must start with '# shellcheck shell=bash'." >&2
    failed=1
  fi

  if grep -q '^#!/usr/bin/env bash$' "$file_path"; then
    echo "[Error] ${rel_path} is sourced and must not contain '#!/usr/bin/env bash' anywhere in the file." >&2
    failed=1
  fi
done < <(_iter_lib_shell_files)

if [ "$failed" -ne 0 ]; then
  exit 1
fi

echo "[tests] nginx_directives_module_sourcing_style.sh: PASS (lib shebang policy)"
