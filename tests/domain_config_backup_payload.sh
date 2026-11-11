#!/usr/bin/env bash
# Shared fixture variables are consumed by sourced production modules.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils logging backends nginx nginx_directives ports certs backups global_settings http_version tls mtls headers security_rules domain_config cli/upgrade_preflight; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/${module}.sh"
done
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-domain-backup.XXXXXX")"
test_root_logical="$test_root"
# Issuer containment compares physical paths, including macOS /var aliases.
test_root="$(cd "$test_root" && pwd -P)"
trap 'rm -rf "$test_root"' EXIT
STATE_DIR="$test_root/state"
DOMAINS_DIR="$STATE_DIR/domains"
CONFIG_DIR="$STATE_DIR/config"
BACKUP_DIR="$STATE_DIR/backups"
TMP_DIR="$STATE_DIR/tmp"
CERTS_DIR="$STATE_DIR/certs"
_domain_config_bind_config "$CONFIG_DIR"
SKIP_DOCKER_CHECKS=true
INTERACTIVE=false
config_reset_defaults
mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$TMP_DIR" "$STATE_DIR/shared/acme/live/example.com" "$STATE_DIR/shared/acme/archive/example.com"
printf '%s\n' 5 >"$CONFIG_DIR/state_schema_version"
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
mkdir -p "$test_root/legacy/config"
domain_config_backup_needs_restore "$test_root/legacy" || {
  printf '%s\n' '[Error] Schema-5 code must stage legacy restore conversion.' >&2
  exit 1
}

function fail_test() { printf '[Error] %s\n' "$*" >&2; exit 1; }
# The production entrypoint already owns the same lock; do not lock the checkout
# while this fixture tests only snapshot data and public intake contracts.
function _config_begin_runtime_prep_lock_if_needed() { printf -v "$1" '%s' false; }
function _config_end_runtime_prep_lock_if_started() { :; }

domain_dir="$DOMAINS_DIR/example.com"
_domain_csv_initialize "$domain_dir/config"
printf '%s\n' 'schema_version,role,target' '5,certificate-only,' >"$domain_dir/config/domain.csv"
_domain_config_copy_inputs "$domain_dir/config" "$domain_dir/runtime/applied"
printf '%s\n' 'unfinished,"draft' >"$domain_dir/config/settings.csv"
mkdir -p "$domain_dir/certs/custom-443" "$domain_dir/mtls" "$domain_dir/generated" "$domain_dir/runtime/transactions" "$CONFIG_DIR/nginx_conf" "$CONFIG_DIR/proxy_certs"
printf '%s\n' 'private-material' >"$domain_dir/certs/custom-443/privkey.pem"
chmod 400 "$domain_dir/certs/custom-443/privkey.pem"
printf '%s\n' 'ca-material' >"$domain_dir/mtls/ca.key"
printf '%s\n' excluded >"$domain_dir/generated/http.conf"
printf '%s\n' excluded >"$domain_dir/runtime/transactions/journal.csv"
printf '%s\n' excluded >"$CONFIG_DIR/nginx_conf/nginx.conf"
printf '%s\n' excluded >"$CONFIG_DIR/proxy_certs/private-copy.pem"
printf '%s\n' issuer-material >"$STATE_DIR/shared/acme/archive/example.com/fullchain1.pem"
ln -s ../../archive/example.com/fullchain1.pem "$STATE_DIR/shared/acme/live/example.com/fullchain.pem"

snapshot="$BACKUP_DIR/domain-snapshot"
domain_config_backup_write "$snapshot"
[ -f "$snapshot/backup_manifest.csv" ] || fail_test 'Backup manifest missing.'
cmp -s "$domain_dir/config/settings.csv" "$snapshot/domains/example.com/config/settings.csv" || fail_test 'Unfinished draft was not preserved.'
cmp -s "$domain_dir/runtime/applied/settings.csv" "$snapshot/domains/example.com/runtime/applied/settings.csv" || fail_test 'Applied snapshot missing.'
[ "$(_restore_intake_file_mode "$snapshot/domains/example.com/certs/custom-443/privkey.pem")" = 00400 ] || fail_test 'Private key mode widened.'
for excluded in domains/example.com/generated domains/example.com/runtime/transactions config/nginx_conf config/proxy_certs; do
  [ ! -e "$snapshot/$excluded" ] || fail_test "Excluded runtime artifact copied: $excluded"
done
[ ! -L "$snapshot/shared/acme/live/example.com/fullchain.pem" ] || fail_test 'Public backup must contain regular files.'
grep -Fq 'shared/acme/live/example.com/fullchain.pem,../../archive/example.com/fullchain1.pem' "$snapshot/issuer_links.csv" || fail_test 'Issuer link metadata missing.'

# Native macOS aliases may appear in a checkout's state root. Preserve this
# logical spelling specifically for the issuer-copy regression, while the rest
# of this low-level fixture uses physical paths for exact comparisons/hooks.
if [ "$(uname -s)" = Darwin ]; then
  case "$test_root_logical" in /private/var/* | /private/tmp/*) test_root_logical="${test_root_logical#/private}" ;; esac
  case "$test_root_logical" in
  /var/* | /tmp/*)
    alias_copy="$test_root/native-alias-copy"
    mkdir "$alias_copy"
    _domain_backup_copy_tree "$test_root_logical/state/shared/acme/live/example.com/fullchain.pem" \
      "$alias_copy/fullchain.pem" shared/acme/live/example.com/fullchain.pem "$alias_copy/issuer_links.csv" || fail_test 'Native system alias rejected a contained issuer file.'
    cmp -s "$alias_copy/fullchain.pem" "$STATE_DIR/shared/acme/archive/example.com/fullchain1.pem" || fail_test 'Native-alias issuer payload changed.'
    grep -Fqx 'shared/acme/live/example.com/fullchain.pem,../../archive/example.com/fullchain1.pem' "$alias_copy/issuer_links.csv" || fail_test 'Native-alias issuer link metadata missing.'
    ;;
  esac
fi

# Resolving an arbitrary symlink is never a substitute for verified archive
# ancestry, even when the resolved target is another valid local issuer tree.
for unsafe_component in prefix archive lineage leaf; do
  unsafe_root="$test_root/unsafe-issuer-$unsafe_component"
  if [ "$unsafe_component" = prefix ]; then
    ln -s "$STATE_DIR/shared/acme" "$unsafe_root"
  else
    mkdir -p "$unsafe_root/live/example.com"
    ln -s ../../archive/example.com/fullchain1.pem "$unsafe_root/live/example.com/fullchain.pem"
    case "$unsafe_component" in
    archive) ln -s "$STATE_DIR/shared/acme/archive" "$unsafe_root/archive" ;;
    lineage)
      mkdir "$unsafe_root/archive"
      ln -s "$STATE_DIR/shared/acme/archive/example.com" "$unsafe_root/archive/example.com"
      ;;
    leaf)
      mkdir -p "$unsafe_root/archive/example.com"
      ln -s "$STATE_DIR/shared/acme/archive/example.com/fullchain1.pem" "$unsafe_root/archive/example.com/fullchain1.pem"
      ;;
    esac
  fi
  if _domain_backup_copy_tree "$unsafe_root/live/example.com/fullchain.pem" \
    "$test_root/unsafe-copy-$unsafe_component/fullchain.pem" shared/acme/live/example.com/fullchain.pem "$test_root/unsafe-links-$unsafe_component.csv" >"$test_root/unsafe-$unsafe_component.out" 2>&1; then
    fail_test "Issuer copy accepted an arbitrary $unsafe_component symlink."
  fi
  [ ! -e "$test_root/unsafe-copy-$unsafe_component/fullchain.pem" ] || fail_test 'Unsafe issuer bytes reached the backup.'
done

before="$(domain_config_backup_checksum)"
printf '%s\n' 'another unfinished draft' >"$domain_dir/config/settings.csv"
after="$(domain_config_backup_checksum)"
[ "$before" != "$after" ] || fail_test 'Pending edits must affect backup deduplication.'

# Restore validates applied state while leaving the invalid pending source alone.
_domain_restore_build_candidate "$snapshot/domains" "$test_root/candidate"
printf 'domain\nexample.com\n' >"$snapshot/config/domain_inventory.csv"
_domain_restore_validate_inventory "$snapshot/config" "$test_root/candidate" || fail_test 'Complete applied inventory rejected.'
printf 'missing.example.com\n' >>"$snapshot/config/domain_inventory.csv"
if _domain_restore_validate_inventory "$snapshot/config" "$test_root/candidate" >"$test_root/incomplete.out" 2>&1; then
  fail_test 'Backup with a missing applied domain was accepted.'
fi
printf 'domain\nexample.com\n' >"$snapshot/config/domain_inventory.csv"
_domain_backup_restore_issuer_links "$snapshot"
[ "$(readlink "$snapshot/shared/acme/live/example.com/fullchain.pem")" = ../../archive/example.com/fullchain1.pem ] || fail_test 'Validated issuer link was not reconstructed.'

# Applied declarations restore metadata without contacting an issuer or parsing
# unfinished drafts. Unreferenced saved material remains available for cleanup.
cert_restore="$test_root/cert-restore"
_domain_config_copy_inputs "$test_root/candidate/example.com/config" "$cert_restore/candidate/example.com/config"
mkdir -p "$cert_restore/domains/example.com/certs/selfsigned-443" "$cert_restore/domains/example.com/certs/retained-443"
printf '%s\n' 'certificate_id,provider,port_suffix,source_fullchain,source_privkey' 'selfsigned-443,selfsigned,443,,' >"$cert_restore/candidate/example.com/config/certificates.csv"
printf '%s\n' 'provider,port_suffix,source_ref,declared,specification,source_fullchain,source_privkey' ',,,no,,,' >"$cert_restore/domains/example.com/certs/selfsigned-443/certificate.csv"
printf '%s\n' 'provider,port_suffix,source_ref,declared,specification,source_fullchain,source_privkey' ',,,yes,,,' >"$cert_restore/domains/example.com/certs/retained-443/certificate.csv"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=example.com \
  -keyout "$cert_restore/domains/example.com/certs/selfsigned-443/privkey.pem" \
  -out "$cert_restore/domains/example.com/certs/selfsigned-443/fullchain.pem" >/dev/null 2>&1
_domain_restore_prepare_certificates "$cert_restore" || fail_test 'Saved declared certificate could not be restored.'
[ "$(_domain_runtime_get "$cert_restore/domains/example.com/certs/selfsigned-443/certificate.csv" declared)" = yes ] || fail_test 'Applied certificate remained marked as retained.'
[ "$(_domain_runtime_get "$cert_restore/domains/example.com/certs/retained-443/certificate.csv" declared)" = no ] || fail_test 'Unreferenced certificate remained declared.'
printf '%s\n' 'certificate_id,provider,port_suffix,source_fullchain,source_privkey' 'selfsigned-443,custom,443,/missing/import/fullchain.pem,/missing/import/privkey.pem' >"$cert_restore/candidate/example.com/config/certificates.csv"
_domain_restore_prepare_certificates "$cert_restore" || fail_test 'Custom certificate metadata could not be restored.'
(
  DOMAIN_CONFIG_RESTORE_MATERIAL=true
  DOMAIN_CONFIG_RESTORE_MATERIAL_ROOT="$cert_restore/domains"
  domain_config_validate_directory example.com "$cert_restore/candidate/example.com/config"
) || fail_test 'Restore rejected staged custom material whose original upload sources are gone.'
rm "$cert_restore/domains/example.com/certs/selfsigned-443/privkey.pem"
if _domain_restore_prepare_certificates "$cert_restore" >"$test_root/missing-material.out" 2>&1; then
  fail_test 'Missing applied certificate material was accepted.'
fi

ln -s "$test_root/outside" "$domain_dir/config/escape.csv"
printf '%s\n' external >"$test_root/outside"
if domain_config_backup_write "$test_root/rejected" >"$test_root/rejected.out" 2>&1; then
  fail_test 'Unapproved source symlink accepted.'
fi
rm "$domain_dir/config/escape.csv"
if _domain_backup_validate_issuer_link shared/acme/live/example.com/fullchain.pem ../../archive/other.example/fullchain1.pem; then
  fail_test 'Cross-lineage issuer link accepted.'
fi

chmod 400 "$snapshot/config/global_settings.csv"
_domain_restore_copy_global_config "$snapshot/config" || fail_test 'Restored global configuration could not be published.'
[ "$(_restore_intake_file_mode "$GLOBAL_SETTINGS_FILE")" = 00400 ] || fail_test 'Restore widened a tighter saved-settings mode.'

printf '%s\n' domain-backup/ domain-backup/config/ domain-backup/backup_manifest.csv domain-backup/domains/ domain-backup/shared/ |
  upgrade_preflight_backup_archive_validate_listing domain-backup || fail_test 'Domain backup should satisfy upgrade preflight.'
if printf '%s\n' domain-backup/config/ domain-backup/backup_manifest.csv |
  upgrade_preflight_backup_archive_validate_listing domain-backup; then
  fail_test 'Incomplete domain backup should not satisfy upgrade preflight.'
fi
mkdir -p "$test_root/archive-input/incomplete/config"
printf '%s\n' 5 >"$test_root/archive-input/incomplete/config/state_schema_version"
tar -czf "$test_root/incomplete.tar.gz" -C "$test_root/archive-input" incomplete
if upgrade_preflight_backup_archive_is_full "$test_root/incomplete.tar.gz" incomplete.tar.gz; then
  fail_test 'Schema-2 config-only archive should not satisfy upgrade preflight.'
fi
printf '%s\n' '[tests] domain_config_backup_payload.sh: PASS'
