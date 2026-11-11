# shellcheck shell=bash

# Both supported tar implementations otherwise auto-detect another compressed
# layer. Admit a genuine first tar header before any tar invocation; the literal
# filter below then prevents every subsequent automatic decompression layer.
function _restore_intake_validate_raw_tar() {
  local raw="${1:-}"
  if ! LC_ALL=C od -An -v -t u1 -N512 "$raw" | LC_ALL=C awk '
    function number(first, width, i, end) {
      end=first+width
      if (b[first] == 128 || b[first] == 255) return 1
      i=first
      while (i < end && b[i] == 32) i++
      while (i < end && b[i] >= 48 && b[i] <= 55) i++
      while (i < end && (b[i] == 0 || b[i] == 32)) i++
      return i == end
    }
    { for (i=1; i<=NF; i++) b[++n]=$i }
    END {
      if (n != 512 || b[1] == 0) exit 1
      # Names use a NUL-padded fixed field. Control-byte prefixes cannot be
      # disguised as tar by embedding magic/checksum bytes in gzip extras.
      ended=0
      for (i=1; i<=100; i++) {
        if (b[i] == 0) ended=1
        else if (ended || b[i] < 32 || b[i] == 127 || b[i] == 92) exit 1
      }
      checksum=0; digits=0; tail=0
      for (i=149; i<=156; i++) {
        if (b[i] >= 48 && b[i] <= 55 && !tail) {
          checksum=checksum*8+b[i]-48; digits++
        } else if (b[i] == 0 || b[i] == 32) {
          if (digits) tail=1
        } else exit 1
      }
      if (!digits) exit 1
      unsigned_sum=0; signed_sum=0
      for (i=1; i<=512; i++) {
        byte=(i>=149 && i<=156) ? 32 : b[i]
        unsigned_sum+=byte
        signed_sum+=(byte>127) ? byte-256 : byte
      }
      if (checksum != unsigned_sum && checksum != signed_sum) exit 1
      posix=(b[258]==117 && b[259]==115 && b[260]==116 && b[261]==97 && b[262]==114 && b[263]==0 && b[264]==48 && b[265]==48)
      gnu=(b[258]==117 && b[259]==115 && b[260]==116 && b[261]==97 && b[262]==114 && b[263]==32 && b[264]==32 && b[265]==0)
      if (!posix && !gnu) {
        # Preserve old V7 tar backups, whose extension area is all zero.
        for (i=258; i<=512; i++) if (b[i] != 0) exit 1
      }
      type=b[157]
      if (type!=0 && type!=48 && type!=53 && type!=83 && type!=120 && type!=103 && type!=76 && type!=75) exit 1
      if (!number(101,8) || !number(109,8) || !number(117,8) || !number(125,12) || !number(137,12)) exit 1
      if ((posix || gnu) && (!number(330,8) || !number(338,8))) exit 1
    }
  '; then
    echo "[Error] Expected a plain tar stream after gzip expansion; nested compression, other archive formats, and invalid tar headers are not supported." >&2
    return 1
  fi
}

function _restore_intake_member_name() {
  local name="${1:-}" component="" normalized=""
  [ -n "$name" ] || return 1
  [[ "$name" != *\\* && ! "$name" =~ [[:cntrl:]] ]] || return 1
  case "$name" in /* | [A-Za-z]:*) return 1 ;; esac
  while [ -n "$name" ]; do
    component="${name%%/*}"
    if [ "$component" = "$name" ]; then name=""; else name="${name#*/}"; fi
    case "$component" in
    '' | .) continue ;;
    ..) return 1 ;;
    esac
    normalized="${normalized:+${normalized}/}${component}"
  done
  [ -n "$normalized" ] || return 1
  printf '%s\n' "$normalized"
}

# Read bounded chunks, not an unbounded attacker-controlled listing line. The
# filesystem cannot restore a member whose displayed path exceeds this bound.
function _restore_intake_listing_sink() {
  local destination="${1:-}" entry_limit="${2:-}" byte_limit="${3:-}"
  local kind="${4:-names}" implementation="${5:-gnu}" line="" count=0 total=0 size=0
  local permission="" owner="" group="" links="" rest="" declared="" type=""
  local listing_bytes=0
  : >"$destination" || return 1
  while IFS= read -r -n 8193 line || [ -n "$line" ]; do
    if [ "${#line}" -gt 8192 ]; then
      echo "[Error] Backup archive has an overlong member listing." >&2
      return 1
    fi
    count=$((count + 1))
    if [ "$count" -gt "$entry_limit" ]; then
      echo "[Error] Backup archive exceeds RESTORE_MAX_ENTRIES ($entry_limit)." >&2
      return 1
    fi
    listing_bytes=$((listing_bytes + ${#line} + 1))
    if [ "$listing_bytes" -gt "$byte_limit" ]; then
      echo "[Error] Backup archive listing exceeds RESTORE_MAX_EXPANDED_BYTES ($byte_limit)." >&2
      return 1
    fi
    if [ "$kind" = details ]; then
      type="${line:0:1}"
      case "$type" in - | d) ;; *)
        echo "[Error] Backup archive contains an unsupported member type." >&2
        return 1
        ;;
      esac
      if [ "$implementation" = gnu ]; then
        IFS=' ' read -r permission owner declared rest <<<"$line"
      else
        IFS=' ' read -r permission links owner group declared rest <<<"$line"
      fi
      size="$(_restore_intake_decimal "$declared" "Backup member size" true)" || return 1
      if [ "$size" -gt "$((byte_limit - total))" ]; then
        echo "[Error] Backup file sizes exceed RESTORE_MAX_EXPANDED_BYTES ($byte_limit)." >&2
        return 1
      fi
      total=$((total + size))
    fi
    printf '%s\n' "$line" >>"$destination" || return 1
    line=""
  done
}

function _restore_intake_archive_members() {
  local raw="${1:-}" workspace="${2:-}" expanded_limit="${3:-}" entry_limit="${4:-}" implementation="${5:-}"
  local names="$workspace/member_names" details="$workspace/member_details" records="$workspace/member_records"
  local locale_name=C name="" detail="" normalized="" type="" count=0
  local -a quoting=()
  [ "$implementation" != gnu ] || quoting=(--quoting-style=escape)
  locale_name="$(_transaction_archive_locale)" || return 1
  # Every producer status is observed. A member/byte limit closes its listing
  # pipe immediately, and pipefail waits for/reaps tar before cleanup.
  if [ "${#quoting[@]}" -gt 0 ]; then
    if ! TAR_OPTIONS='' TAR_READER_OPTIONS='' LC_ALL="$locale_name" tar -tf "$raw" --ignore-zeros --use-compress-program='sh -c cat' "${quoting[@]}" |
      _restore_intake_listing_sink "$names" "$entry_limit" "$expanded_limit"; then return 1; fi
    if ! TAR_OPTIONS='' TAR_READER_OPTIONS='' LC_ALL="$locale_name" tar -tvf "$raw" --ignore-zeros --use-compress-program='sh -c cat' --numeric-owner "${quoting[@]}" |
      _restore_intake_listing_sink "$details" "$entry_limit" "$expanded_limit" details "$implementation"; then return 1; fi
  else
    if ! TAR_OPTIONS='' TAR_READER_OPTIONS='' LC_ALL="$locale_name" tar -tf "$raw" --ignore-zeros --use-compress-program='sh -c cat' |
      _restore_intake_listing_sink "$names" "$entry_limit" "$expanded_limit"; then return 1; fi
    if ! TAR_OPTIONS='' TAR_READER_OPTIONS='' LC_ALL="$locale_name" tar -tvf "$raw" --ignore-zeros --use-compress-program='sh -c cat' --numeric-owner |
      _restore_intake_listing_sink "$details" "$entry_limit" "$expanded_limit" details "$implementation"; then return 1; fi
  fi
  : >"$records" || return 1
  while IFS= read -r name; do
    IFS= read -r detail <&4 || return 1
    normalized="$(_restore_intake_member_name "$name")" || {
      echo "[Error] Backup archive contains an unsafe member path." >&2
      return 1
    }
    type="${detail:0:1}"
    printf '%s\t%s\n' "$type" "$normalized" >>"$records" || return 1
    count=$((count + 1))
  done <"$names" 4<"$details"
  [ "$count" -gt 0 ] || {
    echo "[Error] Backup archive must contain a single top-level directory." >&2
    return 1
  }
  # Counting implicit parents prevents one deeply nested member from creating
  # many uncounted directories. Conflicting/duplicate paths fail before writes.
  if ! LC_ALL=C awk -F '\t' -v limit="$entry_limit" '
    function remember(path, kind) {
      if (!(path in kinds)) {
        kinds[path]=kind
        total++
        if (total > limit) { print "[Error] Backup paths exceed RESTORE_MAX_ENTRIES (" limit ")." > "/dev/stderr"; exit 1 }
      } else if (kinds[path] != kind) { bad=1 }
    }
    {
      if (explicit[$2]++) bad=1
      remember($2, $1)
      parent=$2
      while (sub(/\/[^\/]*$/, "", parent)) remember(parent, "d")
    }
    END { if (bad) { print "[Error] Backup archive contains duplicate or conflicting paths." > "/dev/stderr"; exit 1 } }
  ' "$records"; then return 1; fi
}

function _restore_intake_archive() {
  local source="${1:-}" workspace="${2:-}" archive_limit="${3:-}" expanded_limit="${4:-}" entry_limit="${5:-}"
  local snapshot="$workspace/archive.tar.gz" raw="$workspace/archive.tar" version="" implementation="" locale_name=C
  _restore_intake_copy_regular "$source" "$snapshot" "$archive_limit" "Compressed backup archive (RESTORE_MAX_ARCHIVE_BYTES)" || return 1
  chmod 400 "$snapshot" || return 1
  _restore_intake_checksum "$source" "$snapshot" "$workspace" || return 1
  # gzip -l reports only the final concatenated member and wraps large sizes.
  # Bound the actual complete stream instead, including trailing tar padding.
  if ! GZIP='' gzip -dc <"$snapshot" |
    _restore_intake_bounded_stream "$raw" "$expanded_limit" "Expanded tar stream (RESTORE_MAX_EXPANDED_BYTES)"; then
    echo "[Error] Unable to expand backup archive within the restore limits." >&2
    return 1
  fi
  chmod 400 "$raw" || return 1
  _restore_intake_validate_raw_tar "$raw" || return 1
  version="$(TAR_OPTIONS='' LC_ALL=C tar --version 2>/dev/null || exit 1)" || return 1
  case "$version" in
  *"GNU tar"*) implementation=gnu ;;
  *bsdtar* | *libarchive*) implementation=bsd ;;
  *) echo "[Error] Unsupported tar implementation for safe restore intake." >&2; return 1 ;;
  esac
  _restore_intake_archive_members "$raw" "$workspace" "$expanded_limit" "$entry_limit" "$implementation" || return 1
  mkdir -m 700 "$workspace/extracted" || return 1
  locale_name="$(_transaction_archive_locale)" || return 1
  if [ "$implementation" = gnu ]; then
    TAR_OPTIONS='' TAR_READER_OPTIONS='' COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 LC_ALL="$locale_name" \
      tar -xf "$raw" --ignore-zeros --use-compress-program='sh -c cat' -C "$workspace/extracted" --no-same-owner --no-same-permissions --no-acls --no-xattrs || return 1
  else
    TAR_OPTIONS='' TAR_READER_OPTIONS='' COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 LC_ALL="$locale_name" \
      tar -xof "$raw" --ignore-zeros --use-compress-program='sh -c cat' -C "$workspace/extracted" --no-acls --no-xattrs --no-fflags --no-mac-metadata || return 1
  fi
  _validate_backup_directory_tree_safe "$workspace/extracted"
}
