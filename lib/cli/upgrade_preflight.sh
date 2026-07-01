# shellcheck shell=bash

UPGRADE_PREFLIGHT_BACKUP_ARCHIVE_MAX_ENTRIES="${UPGRADE_PREFLIGHT_BACKUP_ARCHIVE_MAX_ENTRIES:-20000}"
UPGRADE_PREFLIGHT_BACKUP_ARCHIVE_MAX_ENTRY_LENGTH="${UPGRADE_PREFLIGHT_BACKUP_ARCHIVE_MAX_ENTRY_LENGTH:-4096}"

function upgrade_preflight_usage() {
  cat <<'EOF'
Usage: ./dockistrate.sh upgrade-preflight [--require-backup] [vMAJOR.MINOR.PATCH]

Read-only compatibility check for the current state directory and, optionally,
a local release tag. This command never fetches tags, checks remotes, starts
Docker, repairs config, audits, or migrates state.
EOF
}

function upgrade_preflight_error_usage() {
  echo "[Error] $1" >&2
  upgrade_preflight_usage >&2
  return 2
}

function upgrade_preflight_validate_tag() {
  local tag="${1:-}"

  [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

function upgrade_preflight_validate_version() {
  local version="${1:-}"

  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

function upgrade_preflight_git_has_local_tag() {
  local tag="${1:-}"

  git -C "$SCRIPT_DIR" rev-parse -q --verify "refs/tags/${tag}^{commit}" >/dev/null 2>&1
}

function upgrade_preflight_git_show_file() {
  local tag="${1:-}" path="${2:-}"

  git -C "$SCRIPT_DIR" show "${tag}:${path}" 2>/dev/null
}

function upgrade_preflight_parse_schema_constant() {
  local source_path="${1:-schema file}" exact_count=0 assignment_count=0 line="" schema=""

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^CURRENT_STATE_SCHEMA_VERSION[[:space:]]*= ]]; then
      assignment_count=$((assignment_count + 1))
      if [[ "$line" =~ ^CURRENT_STATE_SCHEMA_VERSION=\"[1-9][0-9]*\"$ ]]; then
        exact_count=$((exact_count + 1))
        schema="${line#CURRENT_STATE_SCHEMA_VERSION=\"}"
        schema="${schema%\"}"
      fi
    fi
  done

  if [ "$assignment_count" -eq 0 ]; then
    return 2
  fi

  if [ "$exact_count" -ne 1 ] || [ "$assignment_count" -ne 1 ]; then
    echo "[Error] Could not parse state schema constant in ${source_path}: expected exactly CURRENT_STATE_SCHEMA_VERSION=\"N\" with N > 0." >&2
    return 1
  fi

  printf '%s\n' "$schema"
}

function upgrade_preflight_read_target_version() {
  local tag="${1:-}" content="" first_line="" extra_line=""

  if ! content="$(upgrade_preflight_git_show_file "$tag" "VERSION")"; then
    echo "[Error] Target tag ${tag} does not contain a readable VERSION file." >&2
    return 1
  fi

  {
    IFS= read -r first_line || true
    if IFS= read -r extra_line || [ -n "$extra_line" ]; then
      echo "[Error] Target tag ${tag} has an unparseable VERSION file." >&2
      return 1
    fi
  } <<EOF
$content
EOF

  first_line="${first_line%$'\r'}"
  if ! upgrade_preflight_validate_version "$first_line"; then
    echo "[Error] Target tag ${tag} has an unparseable VERSION file." >&2
    return 1
  fi

  printf '%s\n' "$first_line"
}

function upgrade_preflight_read_target_schema() {
  local tag="${1:-}" content="" schema=""

  if content="$(upgrade_preflight_git_show_file "$tag" "lib/config/schema_version.sh")"; then
    schema="$(printf '%s\n' "$content" | upgrade_preflight_parse_schema_constant "lib/config/schema_version.sh")" || return 1
    printf '%s\n' "$schema"
    return 0
  fi

  if content="$(upgrade_preflight_git_show_file "$tag" "lib/config/common.sh")"; then
    schema="$(printf '%s\n' "$content" | upgrade_preflight_parse_schema_constant "lib/config/common.sh")"
    case "$?" in
    0)
      printf '%s\n' "$schema"
      return 0
      ;;
    2)
      printf '%s\n' "1"
      return 0
      ;;
    *)
      return 1
      ;;
    esac
  fi

  echo "[Error] Target tag ${tag} does not contain readable state schema metadata." >&2
  return 1
}

function upgrade_preflight_check_tag_version_match() {
  local tag="${1:-}" version="${2:-}" expected=""

  expected="${tag#v}"
  if [ "$version" != "$expected" ]; then
    echo "[Error] Target tag ${tag} points to VERSION ${version}; expected ${expected}." >&2
    return 3
  fi

  return 0
}

function upgrade_preflight_backup_exists() {
  local item base

  [ -d "$BACKUP_DIR" ] || return 1

  for item in "$BACKUP_DIR"/*; do
    [ -e "$item" ] || continue
    [ ! -L "$item" ] || continue
    base="$(basename "$item")"

    case "$base" in
    .* | *.tmp | *.partial | *.part | *.incomplete | *.sha256 | last_* | [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]_pre_*.tar.gz | [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]_post_*.tar.gz)
      continue
      ;;
    esac

    if [ -d "$item" ] && [ -d "$item/config" ] && [ ! -L "$item/config" ]; then
      return 0
    fi

    case "$base" in
    *.tar.gz)
      upgrade_preflight_backup_archive_is_full "$item" "$base" && return 0
      ;;
    esac
  done

  return 1
}

function upgrade_preflight_backup_archive_is_full() {
  local archive="${1:-}" base="${2:-}" backup_root=""

  [ -f "$archive" ] && [ -s "$archive" ] && [ ! -L "$archive" ] || return 1
  case "$base" in
  *.tar.gz) backup_root="${base%.tar.gz}" ;;
  *) return 1 ;;
  esac
  [ -n "$backup_root" ] || return 1

  if ! (
    set -o pipefail
    LC_ALL=C tar -tzf "$archive" 2>/dev/null |
      upgrade_preflight_backup_archive_validate_listing "$backup_root"
  ); then
    return 1
  fi

  return 0
}

function upgrade_preflight_backup_archive_validate_listing() {
  local backup_root="${1:-}" entry="" found_config=false
  local entry_count=0 max_entries="${UPGRADE_PREFLIGHT_BACKUP_ARCHIVE_MAX_ENTRIES:-20000}"
  local max_entry_length="${UPGRADE_PREFLIGHT_BACKUP_ARCHIVE_MAX_ENTRY_LENGTH:-4096}"

  [ -n "$backup_root" ] || return 1
  case "$max_entries" in
  "" | *[!0-9]*)
    max_entries=20000
    ;;
  esac
  case "$max_entry_length" in
  "" | *[!0-9]*)
    max_entry_length=4096
    ;;
  esac
  if [ "$max_entries" -le 0 ]; then
    max_entries=20000
  fi
  if [ "$max_entry_length" -le 0 ]; then
    max_entry_length=4096
  fi

  while IFS= read -r entry || [ -n "$entry" ]; do
    entry_count=$((entry_count + 1))
    [ "$entry_count" -le "$max_entries" ] || return 1
    [ "${#entry}" -le "$max_entry_length" ] || return 1
    [ -n "$entry" ] || continue
    case "$entry" in
    ./*) entry="${entry#./}" ;;
    esac
    case "$entry" in
    "" | /* | \\* | [A-Za-z]:* | [A-Za-z]:\\* | . | ./ | .. | ../ | *../* | ../* | */..)
      return 1
      ;;
    esac
    case "$entry" in
    "$backup_root" | "$backup_root/" | "$backup_root/"*) ;;
    *) return 1 ;;
    esac
    case "$entry" in
    "$backup_root/config" | "$backup_root/config/" | "$backup_root/config/"*)
      found_config=true
      ;;
    esac
  done

  [ "$found_config" = true ]
}

function upgrade_preflight_check_backup() {
  local require_backup="${1:-false}"

  if upgrade_preflight_backup_exists; then
    echo "[Info] Backup: found"
    return 0
  fi

  if [ "$require_backup" = true ]; then
    echo "[Error] Backup required but no backup was found under ${BACKUP_DIR}." >&2
    return 5
  fi

  echo "[Warn] Backup: no backup found under ${BACKUP_DIR}." >&2
  return 0
}

function upgrade_preflight_compare_schema() {
  local local_schema="${1:-}" target_schema="${2:-}"

  if [ "$local_schema" -gt "$target_schema" ]; then
    echo "[Error] cannot downgrade state from ${local_schema} to ${target_schema}" >&2
    return 4
  fi

  return 0
}

function upgrade_preflight_warn_security_rule_operator_fix() {
  local rules_file="${SECURITY_RULES_DB:-${SECURITY_RULES_FILE:-}}" header="" line="" line_no=0 affected_rows=0
  [ -n "$rules_file" ] || return 0
  [ -f "$rules_file" ] || return 0

  if ! declare -F csv_require_header >/dev/null 2>&1; then
    # Support direct sourcing of this update helper without requiring lib/utils.sh first.
    # shellcheck source=../utils/csv.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/utils/csv.sh"
  fi
  if [ -z "${STATE_SECURITY_RULES_HEADER:-}" ]; then
    # shellcheck source=../utils/state_csv.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/utils/state_csv.sh"
  fi

  if ! IFS= read -r header <"$rules_file"; then
    return 0
  fi
  if [ "$header" != "$STATE_SECURITY_RULES_HEADER" ]; then
    return 0
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_SECURITY_RULES_COLS" ] || continue

    local i base cond row_affected=false
    for i in 1 2 3 4 5 6 7 8 9 10; do
      base=$((5 + ((i - 1) * 4)))
      cond="${CSV_FIELDS[$((base + 2))]-}"
      case "$cond" in
      in | not_in | gt | ge | lt | le | exists | not_exists)
        row_affected=true
        break
        ;;
      esac
    done
    if [ "$row_affected" = true ]; then
      affected_rows=$((affected_rows + 1))
    fi
  done <"$rules_file"

  if [ "$affected_rows" -gt 0 ]; then
    echo "[Warn] Security rules: ${affected_rows} persisted rule row(s) use operators whose generated behavior was corrected to match documented allowed-traffic semantics." >&2
  fi
}

function upgrade_preflight_parse_args() {
  UPGRADE_PREFLIGHT_REQUIRE_BACKUP=false
  UPGRADE_PREFLIGHT_TARGET_TAG=""
  UPGRADE_PREFLIGHT_SHOW_HELP=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
    --require-backup)
      UPGRADE_PREFLIGHT_REQUIRE_BACKUP=true
      ;;
    -h | --help)
      upgrade_preflight_usage
      UPGRADE_PREFLIGHT_SHOW_HELP=true
      return 0
      ;;
    --*)
      upgrade_preflight_error_usage "Unknown option: $1"
      return 2
      ;;
    *)
      if [ -n "$UPGRADE_PREFLIGHT_TARGET_TAG" ]; then
        upgrade_preflight_error_usage "Unexpected argument: $1"
        return 2
      fi
      UPGRADE_PREFLIGHT_TARGET_TAG="$1"
      ;;
    esac
    shift
  done

  if [ -n "$UPGRADE_PREFLIGHT_TARGET_TAG" ] && ! upgrade_preflight_validate_tag "$UPGRADE_PREFLIGHT_TARGET_TAG"; then
    upgrade_preflight_error_usage "Malformed target tag: ${UPGRADE_PREFLIGHT_TARGET_TAG}"
    return 2
  fi

  return 0
}

function upgrade_preflight() {
  local parse_status=0 local_schema="" current_schema="" target_version="" target_schema="" backup_status=0

  upgrade_preflight_parse_args "$@"
  parse_status=$?
  if [ "$parse_status" -ne 0 ]; then
    return "$parse_status"
  fi
  if [ "$UPGRADE_PREFLIGHT_SHOW_HELP" = true ]; then
    return 0
  fi

  current_schema="$(_state_schema_normalize_version "$CURRENT_STATE_SCHEMA_VERSION" "current state schema version")" || return 1
  local_schema="$(state_schema_read_marker_readonly)" || return 4

  echo "[Info] Dockistrate version: ${DOCKISTRATE_VERSION}"
  echo "[Info] Current supported state schema: ${current_schema}"
  echo "[Info] On-disk state schema: ${local_schema}"

  upgrade_preflight_check_backup "$UPGRADE_PREFLIGHT_REQUIRE_BACKUP"
  backup_status=$?
  if [ "$backup_status" -ne 0 ]; then
    return "$backup_status"
  fi
  upgrade_preflight_warn_security_rule_operator_fix

  if [ -n "$UPGRADE_PREFLIGHT_TARGET_TAG" ]; then
    if ! upgrade_preflight_git_has_local_tag "$UPGRADE_PREFLIGHT_TARGET_TAG"; then
      echo "[Error] Local tag not found or unreadable: ${UPGRADE_PREFLIGHT_TARGET_TAG}" >&2
      echo "[Hint] Run: git fetch --tags --prune origin" >&2
      return 3
    fi

    target_version="$(upgrade_preflight_read_target_version "$UPGRADE_PREFLIGHT_TARGET_TAG")" || return 3
    upgrade_preflight_check_tag_version_match "$UPGRADE_PREFLIGHT_TARGET_TAG" "$target_version" || return "$?"
    target_schema="$(upgrade_preflight_read_target_schema "$UPGRADE_PREFLIGHT_TARGET_TAG")" || return 3
    target_schema="$(_state_schema_normalize_version "$target_schema" "target state schema version")" || return 3

    echo "[Info] Target tag: ${UPGRADE_PREFLIGHT_TARGET_TAG}"
    echo "[Info] Target version: ${target_version}"
    echo "[Info] Target supported state schema: ${target_schema}"

    upgrade_preflight_compare_schema "$local_schema" "$target_schema" || return "$?"
  fi

  echo "[Info] Upgrade preflight passed."
  return 0
}
