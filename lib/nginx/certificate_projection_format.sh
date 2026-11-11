# shellcheck shell=bash

# Paths are hex encoded in the private manifest and runtime inspection. No
# pathname is parsed as shell code or split on its literal whitespace.
function _projection_hex() {
  LC_ALL=C od -An -v -tx1 | tr -d ' \n'
}

function _projection_unhex() {
  local output="${1:-}" encoded="${2:-}" escaped="" pair=""
  require_valid_var_name "$output" || return 1
  case "$encoded" in '' | *[!0-9a-f]*) return 1 ;; esac
  [ "$((${#encoded} % 2))" -eq 0 ] || return 1
  while [ -n "$encoded" ]; do
    pair="${encoded:0:2}"
    [ "$pair" != 00 ] || return 1
    escaped="${escaped}\\x${pair}"
    encoded="${encoded:2}"
  done
  printf -v "$output" '%b' "$escaped"
}

function _projection_digest() {
  local digest=""
  digest="$(openssl dgst -sha256 -r)" || return 1
  digest="${digest%% *}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$digest"
}

function _projection_relative() {
  local value="${1:-}" part=""
  case "$value" in '' | /* | */ | *//* | .dockistrate-projection | .dockistrate-projection/*) return 1 ;; esac
  while [ -n "$value" ]; do
    part="${value%%/*}"
    case "$part" in '' | . | ..) return 1 ;; esac
    [ "$part" != "$value" ] || break
    value="${value#*/}"
  done
}

function _projection_generation_name() {
  [[ "${1:-}" =~ ^gen-[0-9a-f]{64}-[a-zA-Z0-9]{8,32}$ ]]
}

function _projection_number() {
  [[ "${1:-}" =~ ^(0|[1-9][0-9]{0,9})$ ]] && [ "$1" -le 4294967295 ]
}

# This parser only accepts canonical records. Caller locals deliberately hold
# its results so nested verification cannot overwrite an outer manifest.
function _projection_manifest_parse() {
  local manifest="${1:-}" line="" extra="" previous="" count=0 ended=false
  local tag="" uid="" gid="" pathhex="" role="" mode="" hash="" path=""
  PROJECTION_MANIFEST_UID=""
  PROJECTION_MANIFEST_GID=""
  PROJECTION_MANIFEST_RECORDS=""
  [[ "$manifest" == *$'\n' ]] || return 1
  {
    IFS= read -r line || return 1
    IFS=: read -r tag uid gid extra <<<"$line"
    [ "$tag" = dockistrate-projection-v2 ] && [ -z "$extra" ] || return 1
    _projection_number "$uid" && _projection_number "$gid" || return 1
    [ "$line" = "$tag:$uid:$gid" ] || return 1
    PROJECTION_MANIFEST_UID="$uid"
    PROJECTION_MANIFEST_GID="$gid"
    while IFS= read -r line; do
      [ "$ended" = false ] || return 1
      case "$line" in
      complete:*)
        [ "$line" = "complete:$count" ] || return 1
        ended=true
        ;;
      *)
        IFS=: read -r pathhex role mode uid gid hash extra <<<"$line"
        [ -z "$extra" ] && [ "$line" = "$pathhex:$role:$mode:$uid:$gid:$hash" ] || return 1
        _projection_unhex path "$pathhex" && _projection_relative "$path" || return 1
        case "$role:${path##*/}" in
        server-cert:fullchain.pem | server-key:privkey.pem | mtls-ca:ca.crt | mtls-crl:ca.crl) ;;
        *) return 1 ;;
        esac
        [[ "$mode" =~ ^[0-7]{1,4}$ ]] && [ "$((8#$mode))" -le 4095 ] || return 1
        [ "$mode" = "$(printf '%o' "$((8#$mode))")" ] || return 1
        if [ "$role" = server-key ]; then [ "$((8#$mode & ~0640))" -eq 0 ] || return 1; fi
        _projection_number "$uid" && _projection_number "$gid" || return 1
        [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
        if [ -n "$previous" ]; then [[ "$previous" < "$pathhex" ]] || return 1; fi
        previous="$pathhex"
        PROJECTION_MANIFEST_RECORDS="${PROJECTION_MANIFEST_RECORDS}${line}"$'\n'
        count=$((count + 1))
        ;;
      esac
    done
    [ -z "$line" ] && [ "$ended" = true ]
  } <<<"${manifest%$'\n'}"
}

# Extract only explicitly public PEM blocks. Keep the existing acceptance of
# multiple public blocks and combined files; never copy surrounding bytes.
function _projection_public_pem() {
  local role="${1:-}" label=""
  case "$role" in mtls-ca) label=CERTIFICATE ;; mtls-crl) label='X509 CRL' ;; *) return 1 ;; esac
  LC_ALL=C awk -v label="$label" '
    { data = data $0 "\n" }
    END {
      begin = "-----BEGIN " label "-----"
      finish = "-----END " label "-----"
      blocks = 0
      while ((start = index(data, begin)) > 0) {
        data = substr(data, start + length(begin))
        stop = index(data, finish)
        if (!stop) break
        encoded = substr(data, 1, stop - 1)
        data = substr(data, stop + length(finish))
        if (encoded ~ /[^A-Za-z0-9+=\/\r\n\t ]/) continue
        gsub(/[\r\n\t ]/, "", encoded)
        if (encoded == "" || length(encoded) % 4 != 0 || encoded !~ /^[A-Za-z0-9+\/]*=?=?$/) exit 1
        plain = encoded
        gsub(/=/, "", plain)
        if (length(plain) < 2) exit 1
        print begin
        for (n = 1; n <= length(encoded); n += 64) print substr(encoded, n, 64)
        print finish
        blocks++
      }
      if (!blocks) exit 1
    }'
}

function _projection_mount_format() {
  printf '%s' '{{range .Mounts}}{{if eq .Destination "/etc/letsencrypt"}}{{printf "mount:%x:%t\n" .Source .RW}}{{end}}{{end}}{{printf "complete\n"}}'
}

function _projection_mount_source() {
  local line="" encoded="" writable="" extra="" count=0 ended=false source=""
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$ended" = false ] || { [ -z "$line" ] || return 1; continue; }
    case "$line" in
    complete) ended=true ;;
    mount:*)
      IFS=: read -r extra encoded writable extra <<<"$line"
      [ -z "$extra" ] && [ "$line" = "mount:$encoded:$writable" ] && [ "$writable" = false ] || return 3
      _projection_unhex source "$encoded" || return 1
      count=$((count + 1))
      ;;
    *) return 1 ;;
    esac
  done
  [ "$ended" = true ] || return 1
  [ "$count" -eq 1 ] || return 3
  printf '%s' "$source"
}
