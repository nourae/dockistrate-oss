# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
