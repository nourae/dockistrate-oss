# shellcheck shell=bash

# Transaction archives retain Certbot's relative links. Public restore archives
# continue to use the stricter, link-free _safe_extract_tar path.
function _transaction_archive_locale() {
  local candidate="" charmap="" available=""
  available="$(LC_ALL=C locale -a 2>/dev/null)" || available=""
  available=$'\n'"$available"$'\n'
  for candidate in C.UTF-8 C.utf8 en_US.UTF-8 UTF-8 "${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}"; do
    # An unavailable locale may report the fallback charset instead of failing.
    case "$available" in *$'\n'"$candidate"$'\n'*) ;; *) continue ;; esac
    charmap="$(LC_ALL="$candidate" locale charmap 2>/dev/null)" || continue
    case "$charmap" in
    UTF-8 | UTF8 | utf8 | utf-8) printf '%s\n' "$candidate"; return 0 ;;
    esac
  done
  printf 'C\n'
}

function _transaction_archive_member_name() {
  local name="${1:-}" component="" normalized=""
  local LC_ALL="${_transaction_listing_locale:-${LC_ALL:-${LC_CTYPE:-${LANG:-C}}}}"
  [ -n "$name" ] || return 1
  # Escaped listings stay unambiguous without sacrificing printable Unicode.
  [[ "$name" != *\\* && ! "$name" =~ [^[:print:]] ]] || return 1
  case "$name" in
  /* | [A-Za-z]:*) return 1 ;;
  esac

  while [ -n "$name" ]; do
    component="${name%%/*}"
    if [ "$component" = "$name" ]; then
      name=""
    else
      name="${name#*/}"
    fi
    case "$component" in
    '' | .) continue ;;
    ..) return 1 ;;
    esac
    normalized="${normalized:+${normalized}/}${component}"
  done
  printf '%s\n' "${normalized:-.}"
}

function _transaction_relative_path_is_contained() {
  local path="${1:-}" component="" depth=0
  case "$path" in
  /* | '') return 1 ;;
  esac
  while [ -n "$path" ]; do
    component="${path%%/*}"
    if [ "$component" = "$path" ]; then
      path=""
    else
      path="${path#*/}"
    fi
    case "$component" in
    '' | .) ;;
    ..)
      [ "$depth" -gt 0 ] || return 1
      depth=$((depth - 1))
      ;;
    *) depth=$((depth + 1)) ;;
    esac
  done
}

function _transaction_relative_link_target() {
  local path="${1:-}" link=""
  # GNU and BSD readlink -n emit the raw target without an output delimiter.
  # Keep a sentinel so command substitution preserves trailing target newlines;
  # Darwin's default output cannot distinguish them from its optional delimiter.
  link="$(readlink -n "$path" && printf '.')" || return 1
  link="${link%.}"
  [[ "$link" != *\\* && ! "$link" =~ [[:cntrl:]] ]] || return 1
  case "$link" in
  '' | /* | [A-Za-z]:*) return 1 ;;
  esac
  printf '%s\n' "$link"
}

function _transaction_path_is_selected() {
  local path="${1:-}" allow_parent="${2:-false}" selected=""
  shift 2
  for selected in "$@"; do
    case "$path" in "$selected" | "$selected"/*) return 0 ;; esac
    if [ "$allow_parent" = true ]; then
      case "$selected" in "$path"/*) return 0 ;; esac
    fi
  done
  return 1
}

function _transaction_link_resolves_inside_tree() {
  local root="${1:-}" pending="${2:-}" resolved="" component="" candidate="" link=""
  local followed=0 allow_parent=false
  shift 2
  _transaction_relative_path_is_contained "$pending" || return 1

  # Resolve one component at a time. A final realpath-prefix check alone would
  # miss an intermediate link that leaves the root and later points back in.
  while [ -n "$pending" ]; do
    component="${pending%%/*}"
    if [ "$component" = "$pending" ]; then
      pending=""
    else
      pending="${pending#*/}"
    fi
    case "$component" in
    '' | .) continue ;;
    ..)
      [ -n "$resolved" ] || return 1
      if [[ "$resolved" == */* ]]; then
        resolved="${resolved%/*}"
      else
        resolved=""
      fi
      continue
      ;;
    esac
    candidate="${root}/${resolved:+${resolved}/}${component}"
    if [ "$#" -gt 0 ]; then
      allow_parent=false
      if [ -d "$candidate" ] && [ ! -L "$candidate" ]; then allow_parent=true; fi
      _transaction_path_is_selected "$candidate" "$allow_parent" "$@" || return 1
    fi
    if [ -L "$candidate" ]; then
      followed=$((followed + 1))
      [ "$followed" -le 40 ] || return 1
      link="$(_transaction_relative_link_target "$candidate")" || return 1
      _transaction_relative_path_is_contained "${resolved:+${resolved}/}${link}" || return 1
      pending="${link}${pending:+/${pending}}"
      continue
    fi
    if [ -n "$pending" ]; then
      [ -d "$candidate" ] || return 1
    else
      [ -f "$candidate" ] || [ -d "$candidate" ] || return 1
    fi
    resolved="${resolved:+${resolved}/}${component}"
  done
  candidate="${root}${resolved:+/${resolved}}"
  [ -f "$candidate" ] || [ -d "$candidate" ] || return 1
  if [ "$#" -gt 0 ]; then
    _transaction_path_is_selected "$candidate" false "$@" || return 1
  fi
}

# Validate producer inputs without first extracting an archive. Physical target
# roots are also the membership boundary for links: live state outside these
# roots will not be present in the transaction snapshot.
function _validate_transaction_backup_targets() {
  local root="${1:-}" target="" physical="" relative="" entry="" hardlink=""
  local _transaction_listing_locale=""
  local complete=false
  local -a selected=()
  shift
  [[ ! "$root" =~ [[:cntrl:]] ]] || return 1
  while [ "$root" != / ] && [ "${root%/}" != "$root" ]; do root="${root%/}"; done
  [ -n "$root" ] && [ -d "$root" ] && [ ! -L "$root" ] || return 1
  root="$(cd "$root" && pwd -P && printf '.')" || return 1
  root="${root%$'\n.'}"
  [ "$root" != / ] || return 1
  _transaction_listing_locale="$(_transaction_archive_locale)" || return 1
  for target in "$@"; do
    [[ ! "$target" =~ [[:cntrl:]] ]] || return 1
    while [ "$target" != / ] && [ "${target%/}" != "$target" ]; do target="${target%/}"; done
    case "$target" in /*) ;; *) return 1 ;; esac
    if [ -L "$target" ]; then
      echo "[Error] Refusing symlinked transaction backup path: $target" >&2
      return 1
    fi
    physical="$(_realpath_portable "$target" && printf '.')" || return 1
    physical="${physical%.}"
    case "$physical" in
    "$root") relative=. ;;
    "$root"/*) relative="${physical#"${root}/"}" ;;
    *)
      echo "[Error] Transaction backup target lies outside its state root: $target" >&2
      return 1
      ;;
    esac
    if ! _transaction_archive_member_name "$relative" >/dev/null; then
      echo "[Error] Transaction backup target has an unsafe member name: $target" >&2
      return 1
    fi
    [ -e "$target" ] || continue
    selected+=("$physical")
  done
  [ "${#selected[@]}" -gt 0 ] || return 0

  # Both supported tar implementations encode repeated inode references as
  # hardlink members. Reject them before mutation rather than create a backup
  # the transaction extractor would refuse to replay.
  hardlink="$(find "${selected[@]}" -type f -links +1 -print -quit)" || return 1
  if [ -n "$hardlink" ]; then
    echo "[Error] Hard-linked files are not supported in transaction snapshots: $hardlink" >&2
    return 1
  fi
  while IFS= read -r -d '' entry; do
    if [ -z "$entry" ]; then
      complete=true
      continue
    fi
    relative="${entry#"${root}/"}"
    [ "$entry" != "$root" ] || relative=.
    if ! _transaction_archive_member_name "$relative" >/dev/null; then
      echo "[Error] Transaction snapshot contains an unsafe member name: $entry" >&2
      return 1
    fi
    if [ -L "$entry" ]; then
      if ! _transaction_link_resolves_inside_tree "$root" "$relative" "${selected[@]}"; then
        echo "[Error] Transaction symlink must resolve within the selected snapshot targets: $entry" >&2
        return 1
      fi
    elif [ ! -f "$entry" ] && [ ! -d "$entry" ]; then
      echo "[Error] Unsupported transaction snapshot entry: $entry" >&2
      return 1
    fi
  done < <(LC_ALL=C find "${selected[@]}" -print0 && printf '\0')
  [ "$complete" = true ]
}

function _validate_transaction_tree_safe() {
  local root="${1:-}" entry="" relative="" complete=false
  local _transaction_listing_locale="${_transaction_listing_locale:-}"
  [[ ! "$root" =~ [[:cntrl:]] ]] || return 1
  while [ "$root" != / ] && [ "${root%/}" != "$root" ]; do root="${root%/}"; done
  [ -n "$root" ] && [ -d "$root" ] && [ ! -L "$root" ] || return 1
  root="$(cd "$root" && pwd -P && printf '.')" || return 1
  root="${root%$'\n.'}"
  [ "$root" != / ] || return 1
  if [ -z "$_transaction_listing_locale" ]; then
    _transaction_listing_locale="$(_transaction_archive_locale)" || return 1
  fi

  while IFS= read -r -d '' entry; do
    if [ -z "$entry" ]; then
      complete=true
      continue
    fi
    relative="${entry#"${root}/"}"
    if ! _transaction_archive_member_name "$relative" >/dev/null; then
      echo "[Error] Transaction tree contains an unsafe entry name." >&2
      return 1
    fi
    if [ -L "$entry" ]; then
      if ! _transaction_link_resolves_inside_tree "$root" "$relative"; then
        echo "[Error] Transaction symlink must resolve within its snapshot tree: $entry" >&2
        return 1
      fi
    elif [ ! -f "$entry" ] && [ ! -d "$entry" ]; then
      echo "[Error] Unsupported transaction snapshot entry: $entry" >&2
      return 1
    fi
  done < <(LC_ALL=C find "$root" -mindepth 1 -print0 && printf '\0')
  # An empty NUL record is emitted only after find succeeds. This preserves its
  # exit status without losing NUL-safe filenames to command substitution.
  [ "$complete" = true ]
}

function _safe_extract_transaction_tar() {
  local archive="${1:-}" target_dir="${2:-}" tar_version="" listing="" details=""
  local _transaction_listing_locale=""
  local entry="" line="" type="" normalized="" records="" existing="" old_umask=""
  local count=0 index=0 status=0
  local -a member_types=() listing_options=() extraction_options=(-p --no-same-owner --no-acls --no-xattrs)
  [ -f "$archive" ] && [ ! -L "$archive" ] || return 1
  [[ ! "$target_dir" =~ [[:cntrl:]] ]] || return 1
  while [ "$target_dir" != / ] && [ "${target_dir%/}" != "$target_dir" ]; do target_dir="${target_dir%/}"; done
  [ -n "$target_dir" ] && [ -d "$target_dir" ] && [ ! -L "$target_dir" ] || return 1
  target_dir="$(cd "$target_dir" && pwd -P && printf '.')" || return 1
  target_dir="${target_dir%$'\n.'}"
  [ "$target_dir" != / ] || return 1
  existing="$(find "$target_dir" -mindepth 1 -maxdepth 1 -print -quit)" || return 1
  if [ -n "$existing" ]; then
    echo "[Error] Transaction extraction requires an empty private staging directory." >&2
    return 1
  fi

  tar_version="$(TAR_OPTIONS='' LC_ALL=C tar --version 2>/dev/null)" || return 1
  case "$tar_version" in
  *"GNU tar"*) listing_options=(--quoting-style=escape) ;;
  *bsdtar* | *libarchive*) extraction_options+=(--no-fflags --no-mac-metadata) ;;
  *)
    echo "[Error] Unsupported tar implementation for transaction extraction." >&2
    return 1
    ;;
  esac
  # BSD tar must decode PAX UTF-8 names before it can list/extract them. Use an
  # available UTF-8 locale on both platforms, retaining escaped control bytes.
  _transaction_listing_locale="$(_transaction_archive_locale)" || return 1

  # Capture both complete listings and their statuses before extraction. Pair
  # names with types in order; never parse a displayed symlink target as data.
  if [ "${#listing_options[@]}" -gt 0 ]; then
    listing="$(TAR_OPTIONS='' LC_ALL="$_transaction_listing_locale" tar -tzf "$archive" "${listing_options[@]}")" || return 1
    details="$(TAR_OPTIONS='' LC_ALL="$_transaction_listing_locale" tar -tzvf "$archive" "${listing_options[@]}")" || return 1
  else
    listing="$(TAR_OPTIONS='' LC_ALL="$_transaction_listing_locale" tar -tzf "$archive")" || return 1
    details="$(TAR_OPTIONS='' LC_ALL="$_transaction_listing_locale" tar -tzvf "$archive")" || return 1
  fi
  if [ -z "$listing" ] && [ -z "$details" ]; then
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    type="${line:0:1}"
    case "$type" in
    - | d | l) ;;
    *)
      echo "[Error] Transaction archive contains an unsupported member type." >&2
      return 1
      ;;
    esac
    member_types+=("$type")
    count=$((count + 1))
  done <<<"$details"
  while IFS= read -r entry || [ -n "$entry" ]; do
    [ "$index" -lt "$count" ] || return 1
    normalized="$(_transaction_archive_member_name "$entry")" || {
      echo "[Error] Transaction archive contains an unsafe member path." >&2
      return 1
    }
    type="${member_types[$index]}"
    [ "$normalized" != . ] || [ "$type" = d ] || return 1
    records+="${type}"$'\t'"${normalized}"$'\n'
    index=$((index + 1))
  done <<<"$listing"
  [ "$index" -eq "$count" ] || return 1

  # Reject duplicates and every member below a symlink, irrespective of archive
  # order. Thus extraction cannot write through an archive-created link. GNU and
  # BSD tar's default traversal protections remain enabled as a second check.
  if ! printf '%s' "$records" | LC_ALL=C awk -F '\t' '
    { if (seen[$2]++) bad=1; if ($1 == "l") links[$2]=1 }
    END {
      for (name in seen) {
        parent=name
        while (sub(/\/[^\/]*$/, "", parent)) {
          if (parent in links) bad=1
        }
      }
      exit bad ? 1 : 0
    }
  '; then
    echo "[Error] Transaction archive has duplicate members or symlink ancestors." >&2
    return 1
  fi

  old_umask="$(umask)"
  umask 077
  # Preserve snapshot modes (including group-readable config/cert files), while
  # leaving ownership and extended metadata with the staging process defaults.
  if TAR_OPTIONS='' LC_ALL="$_transaction_listing_locale" tar -xzf "$archive" -C "$target_dir" "${extraction_options[@]}"; then
    status=0
  else
    status=$?
  fi
  umask "$old_umask"
  # A root '.' member can carry a public directory mode. The staging root is
  # only a private wrapper; it must stay private even after a failed extraction.
  if ! chmod 700 "$target_dir"; then
    echo "[Error] Unable to secure transaction staging directory." >&2
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    echo "[Error] Failed to extract transaction archive into private staging." >&2
    return 1
  fi
  _validate_transaction_tree_safe "$target_dir"
}
