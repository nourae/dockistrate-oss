# shellcheck shell=bash

function _mtls_state_error() {
  printf '[Error] Invalid mTLS authority state: %s\n' "$*" >&2
  return 1
}

# Call only from the pinned authority directory. Never read links, devices, or
# shared hard-linked files as authority material.
function _mtls_state_regular_file() {
  local file="$1"
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    _mtls_state_error "$file must be a readable, non-symlink regular file."
    return 1
  fi
  _secure_fs_stat_path "$file" || return 1
  [ "$SECURE_FS_TYPE:$SECURE_FS_LINKS" = file:1 ] || {
    _mtls_state_error "$file must be an unshared regular file."; return 1;
  }
}

# An absent authority can be created deliberately. Derived configuration and an
# empty output directory alone do not establish an existing authority.
function _mtls_authority_is_empty() (
  local mtls_dir="$1" original="" file="" child=""
  _mtls_original_dir_path original "$mtls_dir" || return 1
  [ ! -L "$original" ] || return 1
  [ -e "$original" ] || return 0
  _mtls_cd_guarded_dir "$original" || return 1
  for file in ./* ./.[!.]* ./..?*; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    case "$file" in
    ./openssl.cnf) _mtls_state_regular_file "$file" || return 1 ;;
    ./newcerts)
      [ -d "$file" ] && [ ! -L "$file" ] || return 1
      for child in "$file"/* "$file"/.[!.]* "$file"/..?*; do
        if [ -e "$child" ] || [ -L "$child" ]; then return 1; fi
      done
      ;;
    *) return 1 ;;
    esac
  done
)

function _mtls_authority_generation_allowed() (
  local mtls_dir="$1" mode="${2:-fresh}" file=""
  case "$mode" in
  fresh) _mtls_authority_is_empty "$mtls_dir" ;;
  replacement)
    # The public replacement command has already performed its explicit reset.
    # Preserve historical .p12 exports, but fail if authority material survived.
    _mtls_cd_guarded_dir "$mtls_dir" || return 1
    for file in ./*.crt ./*.key ./index.txt* ./serial ./crlnumber ./ca.srl ./ca.crl ./newcerts; do
      if [ -e "$file" ] || [ -L "$file" ]; then return 1; fi
    done
    ;;
  *) return 1 ;;
  esac
)

function _mtls_validate_ca_pair() {
  local cert_public="" key_public=""
  _mtls_state_regular_file ca.crt && _mtls_state_regular_file ca.key || return 1
  cert_public="$(openssl x509 -in ca.crt -pubkey -noout 2>/dev/null)" || {
    _mtls_state_error 'ca.crt is not a readable certificate.'; return 1;
  }
  # Managed keys are unencrypted. Never prompt for a password during preflight.
  key_public="$(openssl pkey -in ca.key -passin pass: -pubout 2>/dev/null)" || {
    _mtls_state_error 'ca.key is not a readable private key.'; return 1;
  }
  [ -n "$cert_public" ] && [ "$cert_public" = "$key_public" ] || {
    _mtls_state_error 'ca.crt and ca.key do not match.'; return 1;
  }
}

function _mtls_validate_database() {
  local file=""
  for file in index.txt serial crlnumber; do
    _mtls_state_regular_file "$file" || return 1
    # OpenSSL treats NUL as a string terminator and can silently omit database
    # records that awk still sees. Compare bytes without passing NUL through Bash.
    # Both commands only read this file; neither pipeline side writes it.
    # shellcheck disable=SC2094
    LC_ALL=C tr -d '\000' <"$file" | cmp -s "$file" - || {
      _mtls_state_error "$file contains a NUL byte."; return 1;
    }
  done
  for file in serial crlnumber; do
    # OpenSSL reads whole hexadecimal bytes: a bare nibble such as A cannot be
    # loaded as an ASN.1 counter, even though it is a hexadecimal number.
    LC_ALL=C awk 'NR != 1 || $0 !~ /^[0-9a-fA-F]+$/ || length($0)%2 != 0 { bad=1 } END { exit (bad || NR != 1) }' "$file" || {
      _mtls_state_error "$file must contain one even-length hexadecimal counter."; return 1;
    }
  done
  # TXT_DB silently drops an unterminated final record. An unused empty database
  # is valid, but every existing record must end in the delimiter OpenSSL reads.
  if [ -s index.txt ]; then
    tail -c 1 index.txt | cmp -s - <(printf '\n') || {
      _mtls_state_error 'index.txt has an unterminated final record.'; return 1;
    }
  fi
  # OpenSSL uses six tab-separated fields. Empty databases are valid before the
  # first issue; a missing database is never equivalent to that empty database.
  LC_ALL=C awk -F '\t' '
    function date_ok(value, digits, year, month, day, hour, minute, second, days) {
      if (value !~ /^[0-9]+Z$/ || (length(value) != 13 && length(value) != 15)) return 0
      digits=substr(value, 1, length(value)-1)
      if (length(digits) == 12) {
        year=substr(digits,1,2)+0; year+=(year < 50 ? 2000 : 1900)
        digits=substr(digits,3)
      } else { year=substr(digits,1,4)+0; digits=substr(digits,5) }
      month=substr(digits,1,2)+0; day=substr(digits,3,2)+0
      hour=substr(digits,5,2)+0; minute=substr(digits,7,2)+0; second=substr(digits,9,2)+0
      days=31
      if (month == 4 || month == 6 || month == 9 || month == 11) days=30
      if (month == 2) days=28+(year%4 == 0 && (year%100 != 0 || year%400 == 0))
      return month >= 1 && month <= 12 && day >= 1 && day <= days && hour < 24 && minute < 60 && second < 60
    }
    function revocation_ok(value, fields, count) {
      count=split(value,fields,",")
      if (!date_ok(fields[1]) || count > 3) return 0
      if (count == 1) return 1
      if (fields[2] ~ /^(unspecified|keyCompromise|CACompromise|affiliationChanged|superseded|cessationOfOperation|certificateHold|removeFromCRL)$/) return count == 2
      if (fields[2] == "holdInstruction") return count == 3 && fields[3] ~ /^[0-9]+([.][0-9]+)+$/
      if (fields[2] == "keyTime" || fields[2] == "CAkeyTime") return count == 3 && length(fields[3]) == 15 && date_ok(fields[3])
      return 0
    }
    {
      if (NF != 6 || $0 ~ /\r/ || $1 !~ /^(V|R|E)$/ || !date_ok($2) || $4 !~ /^[0-9a-fA-F]+$/ || length($4) < 2 || length($4)%2 != 0 || $5 == "" || $6 == "") { bad=1; next }
      # TXT_DB treats a tab after a backslash as field content, not a separator.
      if ($5 ~ /\\$/) { bad=1; next }
      if (($1 == "R" && !revocation_ok($3)) || ($1 != "R" && $3 != "")) { bad=1; next }
      serial=toupper($4); sub(/^0+/, "", serial); if (serial == "") serial="0"
      if (seen[serial]++) bad=1
    }
    END { exit bad }
  ' index.txt || { _mtls_state_error 'index.txt contains invalid or duplicate issuance/revocation records.'; return 1; }
}

function _mtls_validate_existing_crl() {
  local mode="${1:-core}" crl_text="" verification="" issuer="" subject=""
  _mtls_state_regular_file ca.crl || return 1
  issuer="$(LC_ALL=C openssl crl -in ca.crl -noout -issuer -nameopt RFC2253 2>/dev/null)" || {
    _mtls_state_error 'ca.crl is not a readable revocation list.'; return 1;
  }
  subject="$(LC_ALL=C openssl x509 -in ca.crt -noout -subject -nameopt RFC2253 2>/dev/null)" || return 1
  issuer="${issuer#*=}"; issuer="${issuer# }"
  subject="${subject#*=}"; subject="${subject# }"
  [ -n "$issuer" ] && [ "$issuer" = "$subject" ] || {
    _mtls_state_error 'ca.crl names a different authority.'; return 1;
  }
  # OpenSSL selects the issuer by subject from the explicitly loaded CA file.
  # Check that subject first so an unrelated default-store issuer cannot satisfy
  # verification. Signature verification does not reject expired saved material.
  verification="$(LC_ALL=C openssl crl -in ca.crl -noout -verify -CAfile ca.crt 2>&1)" || {
    _mtls_state_error 'ca.crl is invalid or is not signed by ca.crt.'; return 1;
  }
  # Some releases report verification failure without a failing process status.
  printf '%s\n' "$verification" | grep -Fxq 'verify OK' || {
    _mtls_state_error 'ca.crl is invalid or is not signed by ca.crt.'; return 1;
  }
  crl_text="$(LC_ALL=C openssl crl -in ca.crl -noout -text 2>/dev/null)" || return 1
  # Ordinary reuse must not reinstate a client through an older, validly signed
  # CRL. Only the generator completing a newly recorded revocation permits lag;
  # even there, the database must remember every revocation in the existing CRL.
  LC_ALL=C awk -F '\t' -v mode="$mode" '
    function normalized(value) { value=toupper(value); sub(/^0+/, "", value); return value == "" ? "0" : value }
    FILENAME == ARGV[1] { if ($1 == "R") revoked[normalized($4)]=1; next }
    /^[[:space:]]*Serial Number:/ {
      value=$0; sub(/^[[:space:]]*Serial Number:[[:space:]]*/, "", value); sub(/[[:space:]]*$/, "", value)
      if (value !~ /^[0-9a-fA-F]+$/ || !revoked[normalized(value)]) bad=1
      listed[normalized(value)]=1
    }
    END {
      if (mode != "regenerate") for (serial in revoked) if (!listed[serial]) bad=1
      exit bad
    }
  ' index.txt <(printf '%s\n' "$crl_text") || {
    _mtls_state_error 'ca.crl and index.txt contain inconsistent revocations.'; return 1;
  }
}

# Read-only validation is shared by restore preflight, apply, and every reuse of
# managed authority state. It does not load an archived openssl.cnf or repair it.
function _mtls_validate_authority_state() (
  local mtls_dir="$1" mode="${2:-core}"
  case "$mode" in core | complete | regenerate) ;; *) return 1 ;; esac
  _mtls_cd_guarded_dir "$mtls_dir" || return 1
  _mtls_validate_ca_pair && _mtls_validate_database || return 1
  if [ -e ca.crl ] || [ -L ca.crl ]; then
    _mtls_validate_existing_crl "$mode" || return 1
  elif [ "$mode" = complete ]; then
    _mtls_state_error 'ca.crl is missing.'; return 1
  fi
)
