# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-11-11

This release includes the application, security and documentation changes since
public 1.0.1 (2026-07-01). It requires an explicit upgrade of existing state and
backend ownership. Start with the [1.0.1 to 2.0.0 upgrade guide](docs/guides/updates.md#upgrading-from-101-to-200).
The 1.0.1 backup contains configuration only: preserve a complete offline copy
of pre-upgrade state, including certificate/mTLS/ACME material, and back up
application data separately.

### Breaking changes and migration

- Replaced the schema-1 shared editing layout with schema-5 domain folders under
  `state/domains/<domain>/`. Run `migrate-state --dry-run`, then `migrate-state`
  using the new code. Supply `--backend-details` when legacy image/lifecycle
  declarations cannot be recovered. Schemas 2–4 also require explicit conversion.
  Migration preserves existing rule behavior and does not adopt containers,
  issue certificates or activate drafts.
- Made per-domain CSVs the editable source and `runtime/applied/` the last applied
  snapshot. Legacy aggregate CSVs are generated compatibility views. Manual
  edits require explicit validation and apply; normal startup and rendering
  use applied state. The first apply after schema-1 migration refreshes the
  generated proxy layout. See [domain configuration](docs/guides/domain-configuration.md#upgrade-existing-state).
- Required saved container IDs and launch ownership for backend management.
  Existing 1.0.1 containers need explicit replacement with
  `update-backend <domain> --replace-unmanaged-container <full-id> --image <image>` after
  storage migration. Names alone do not establish ownership. Replacement
  interrupts that backend and does not copy its writable layer; retain mounts,
  volumes and application backups. See [backend upgrades](docs/guides/backends-and-ports.md#backend-identity-and-upgrades).
- Made explicit ACL denies take precedence over overlapping allows, including
  blanket denies. Enforced backend ACLs on ordinary aliases and request rules
  on alternate hostnames, with dedicated-host inheritance respected. Review
  [ACL precedence](docs/guides/access-control-security-rules.md#acl-rule-precedence)
  and test allowed and denied routes after upgrading.
- Applied security-effective trusted-proxy, client-IP, real-IP and inheritance
  changes by replacing the managed proxy and closing existing connections.
  Plan for interruptions when changing these settings.
- Restricted saved interactive commands and application/audit logs to owner-only
  `600` access. Saved global settings default to `640` while preserving tighter
  modes. Group-based readers need owner access or a controlled export; existing
  retained logs/history/backups are not automatically purged.
- Changed verbose trace timestamps to a session start anchor plus elapsed
  seconds. Parsers expecting 1.0.1's per-line calendar timestamps must adapt;
  ordinary audit/application timestamps retain their format.

### Added

- Added **Domain configuration files** to Home and the CLI commands
  `init-domain-config`, `validate-domain-config`, `apply-domain-config` and
  `migrate-state`. Validation, dry-run previews, explicit activation and recovery
  preserve the boundary between pending edits and the serving configuration.
- Added explicit **Block**, **Require** and **Allow** security-rule actions in
  CLI, interactive and editable-file workflows. Migrated rules remain Require.
  Require rules must pass; ordered Allow/Block decisions do not bypass ACLs or
  mTLS. Existing numeric rule IDs and ordering remain usable.
- Added domain-owned certificate and mTLS storage, named-column configuration,
  backup manifests, and recovery support for editable/applied snapshots and
  shared state. Global runtime options, aliases and dedicated-host inheritance
  remain available through CLI and interactive flows.

### Fixed

- Corrected interactive review names and values for path options, security-rule
  updates, Nginx startup, uninstall scope and directive removal. Commands without
  arguments receive none; intentional empty settings still clear values.
  Run/Edit/Cancel, quoting, defaults and optional secret redaction remain intact.
- Fixed **Remove All Backends** confirmation input, existing-path selection,
  conditional prompts and inherited redirect defaults. CLI and interactive
  operations retain the same capabilities.
- Preserved stopped backend state during network changes and cleaned up failed
  launches using immutable ownership evidence. Failed replacement, cleanup and
  transaction completion restore prior runtime/state where possible and report
  incomplete recovery without taking over unrelated same-name containers.
- Preserved pending and concurrent domain edits during mutations, apply,
  migration, restore and rollback. Restored global Nginx directives, removed
  stale path-directive state, and corrected case-insensitive header identity,
  duplicate conflict handling and header-map escaping.
- Made mTLS backups portable across physical state roots while validating CA,
  client, key and revocation relationships. Restored certificate/CRL state
  consistently and rejected incomplete or conflicting material before activation.
- Fixed packet-capture scope validation and combined client/backend filters;
  invalid restrictions fail instead of silently broadening capture. Failed
  launches restore prior TLS-decrypt state. TLS key logging works with non-root
  workers and SNI, and helper changes invalidate stale builds. Stop and re-enable
  TLS-decrypt capture after upgrading to load the current helper.
- Corrected leading empty fields in saved-command arguments, skipped malformed
  saved entries without rewriting them, aligned image pull-mode prompts and
  completion, and retained legacy `yes|no` redirect input compatibility.
- Fixed Bash 3 empty-array and direct-sourcing behavior, checksum/stat portability,
  literal path handling, ACL batch validation, mutation locking and cleanup of
  stale mTLS mappings. Reduced repeated shell processes without skipping
  filesystem, permission or transaction checks.

### Security

- Pinned fresh Nginx `1.31.7` and Certbot `v5.8.0` defaults to reviewed
  multi-platform image digests. Existing saved image selections are preserved;
  update them explicitly using the [image upgrade instructions](docs/security/image-maintenance.md#updating-an-existing-installation).
  A digest pins content, not publisher trust or absence of vulnerabilities.
- Replaced the fresh-install Nginx `1.31.1` default affected by HTTP/3 issue
  CVE-2026-42530. Existing installations retain their saved image selection;
  follow the [HTTP/3 image-update and temporary-disable guidance](docs/guides/tls-certificates-http3.md#http3).
- Limited proxy certificate mounts to the material Nginx needs, keeping CA/client
  private keys and exports out of the proxy. Runtime updates replace old broad
  mounts; see [certificate isolation](docs/guides/tls-certificates-http3.md#proxy-certificate-isolation).
- Validated persisted settings before rendering and restore, rejected unsafe
  Docker-option shapes and malformed security inputs, and preserved valid
  intentional administrator runtime options.
- Hardened restore with private snapshots, bounded archive intake, validated
  paths and metadata, confirmation before extraction, and cancellation cleanup.
  Oversized backups require explicit documented `RESTORE_MAX_*` overrides;
  see [restore limits](docs/guides/backups-restore-cleanup.md#restore-intake-limits).
- Prevented symlink/path races in permission repair, capture output, transaction
  snapshots and cleanup. Permission repair remains scoped to the selected root,
  preserves restrictive private-key access, and reports incomplete rollback
  rather than overwriting concurrent metadata changes.
- Closed optional redaction gaps across review screens, saved commands, audit,
  verbose output and directive values. Full operator visibility remains the
  default; redaction does not erase previously retained copies.

### Documentation and tests

- Replaced the long README with a short illustrated entry point and complete
  walkthroughs for all 24 menu sections, 160 commands and Home features.
  New Hosts and aliases and Mutual TLS guides complement the other task
  guides. Screenshots, copyable inputs, text alternatives, verification and
  recovery steps retain their original source revisions and recordings.
- Repaired function-reference navigation with a generated helper-source index
  and matching HTML. Documentation checks cover links, anchors, source locations,
  command coverage, images, transcripts and capture provenance.
- Retained the regression suite and native macOS Bash 3 coverage. Split domain
  and macOS fast tests into bounded groups without removing tests; public CI
  runs 26 runtime jobs and one documentation job on GitHub-hosted runners.
- Preserved existing demonstration captures. The update-preflight screenshot
  showing `1.0.1` records a private development build with schema 5, not the
  public 1.0.1 release. External ACME outcomes remain explicitly limited by
  domain/DNS prerequisites. The approved 2.0.0 validation scope omits a new
  manual macOS live Docker run; native macOS CI remains required.

## [1.0.1] - 2026-07-01
### Added
- Added `remove-backend --yes` for explicit non-interactive destructive confirmation.

### Fixed
- Fixed security-rule operator behavior for exact list matching, numeric comparison failures, `exists` / `not_exists`, and single/grouped rendering consistency.
- Fixed interactive `add-port` and `update-port` prompts so HTTPS-only certificate, HTTP/3, and Alt-Svc prompts are not shown for non-HTTPS protocols.
- Fixed persisted access-log field handling so tampered state fails closed before generated Nginx log format rendering.
- Fixed saved interactive command history so operator-entered Docker option and header values remain fully visible by default, and added an opt-in redacted visibility policy for display/history/audit copies.
- Fixed exact Docker name matching, direct-sourcing `set -u` guards, and atomic backend state append handling.

## [1.0.0] - 2026-06-10
### Added
- Initial public release of Dockistrate.
- Added CLI and interactive workflows for managing Docker backends behind Nginx.
- Added HTTP, HTTPS, and TCP port routing with generated Nginx configuration.
- Added TLS certificate lifecycle helpers, ACLs, security rules, header controls, backups, diagnostics, packet capture helpers, and Bash completion.
- Documented install, validation, security, compatibility, and operator guidance for the first stable release.
