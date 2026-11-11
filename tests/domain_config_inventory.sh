#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/domain_config.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-domain-inventory.XXXXXXXX")"
trap 'rm -rf "$test_root"' EXIT
STATE_DIR="$test_root/state"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$test_root/candidate"
domain_config_write_template example.com certificate-only "$test_root/candidate/example.com/config"
_domain_config_copy_inputs "$test_root/candidate/example.com/config" "$STATE_DIR/domains/example.com/config"
printf 'example.com\n' >"$test_root/selected"
_domain_config_publish_applied "$test_root/candidate" "$test_root/selected"
_domain_config_mark_cache
_domain_config_cache_current

# Derived cache changes and applied-input changes both invalidate reuse.
printf 'domain,header\n' >"$CONFIG_DIR/backend_headers.csv"
if _domain_config_cache_current; then echo 'Cache ignored a changed output' >&2; exit 1; fi
_domain_config_mark_cache
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\n' >"$STATE_DIR/domains/example.com/runtime/applied/settings.csv"
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\n,,,allow,,\n' >"$STATE_DIR/domains/example.com/runtime/applied/settings.csv"
if _domain_config_cache_current; then echo 'Cache ignored changed inputs' >&2; exit 1; fi

# The inventory survives loss of the entire domain directory. Neither single
# nor all-domain candidate construction may silently turn that into deletion.
mv "$STATE_DIR/domains/example.com" "$test_root/missing-domain"
[ "$(domain_config_list all)" = example.com ]
[ "$(domain_config_status example.com)" = 'missing source' ]
if _domain_config_build_candidate "$test_root/all" --all 2>/dev/null; then echo 'Accepted missing domain source' >&2; exit 1; fi
if _domain_config_build_candidate "$test_root/active" --applied 2>/dev/null; then echo 'Dropped missing applied domain' >&2; exit 1; fi
[ -f "$CONFIG_DIR/domain_inventory.csv" ]

# Unfinished new drafts remain discoverable, but applying all drafts may never
# silently omit a malformed folder or one without the required domain table.
mv "$test_root/missing-domain" "$STATE_DIR/domains/example.com"
draft="$STATE_DIR/domains/draft.example.com"
mkdir -p "$draft/config"
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\n' >"$draft/config/settings.csv"
domain_config_list draft | grep -Fxq draft.example.com
[ "$(domain_config_status draft.example.com)" = 'invalid draft' ]
source "$ROOT_DIR/lib/cli/arg_choices_domain_config.sh"
choices="$(__arg_choices_domain_config_target)"
grep -Fq 'draft.example.com (invalid draft)' <<<"$choices"
_domain_config_build_candidate "$test_root/ignore-new-draft" --applied
[ ! -d "$test_root/ignore-new-draft/candidate/draft.example.com" ]
_domain_config_build_candidate "$test_root/single-domain" example.com
[ ! -d "$test_root/single-domain/candidate/draft.example.com" ]
if _domain_config_build_candidate "$test_root/incomplete" --all 2>/dev/null; then echo 'Omitted incomplete draft' >&2; exit 1; fi
mv "$STATE_DIR/domains/example.com/config/domain.csv" "$test_root/domain.saved"
[ "$(domain_config_status example.com)" = 'missing source' ]
if _domain_config_build_candidate "$test_root/missing-applied-source" example.com 2>/dev/null; then echo 'Accepted missing source from an applied domain' >&2; exit 1; fi
mv "$test_root/domain.saved" "$STATE_DIR/domains/example.com/config/domain.csv"

for malformed in Draft.example.com -draft.example.com; do
  mv "$draft" "$STATE_DIR/domains/$malformed"
  if domain_config_list all | grep -Fxq -- "$malformed"; then echo 'Malformed domain leaked into review choices' >&2; exit 1; fi
  if _domain_config_build_candidate "$test_root/malformed" --all 2>/dev/null; then echo 'Omitted malformed domain draft' >&2; exit 1; fi
  mv "$STATE_DIR/domains/$malformed" "$draft"
done
rm -rf "$draft"
ln -s "$STATE_DIR/domains/example.com" "$draft"
if _domain_config_build_candidate "$test_root/domain-link" --all 2>/dev/null; then echo 'Omitted symlink domain draft' >&2; exit 1; fi
rm "$draft"
mkdir -p "$draft"
ln -s "$STATE_DIR/domains/example.com/config" "$draft/config"
if _domain_config_build_candidate "$test_root/config-link" --all 2>/dev/null; then echo 'Accepted symlink draft config' >&2; exit 1; fi
rm "$draft/config"
mkdir -p "$draft/config"
ln -s "$STATE_DIR/domains/example.com/config/domain.csv" "$draft/config/domain.csv"
if _domain_config_build_candidate "$test_root/domain-file-link" --all 2>/dev/null; then echo 'Accepted symlink domain table' >&2; exit 1; fi
printf '[PASS] domain inventory and cache invalidation\n'
