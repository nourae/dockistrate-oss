# Security Policy

## Supported Versions

Dockistrate supports the current stable release line.

Security fixes are provided for the latest public release unless a separate
maintenance branch is announced.

## Reporting a Vulnerability

Report suspected vulnerabilities privately through
[GitHub Security Advisories](https://github.com/nourae/dockistrate-oss/security/advisories/new)
for `nourae/dockistrate-oss`.

If that channel is unavailable, contact `@nourae` on GitHub.

Please include:

- Dockistrate version or commit.
- Operating system and Bash version.
- Relevant command, configuration, and generated Nginx snippets.
- Reproduction steps and expected impact.

Do not include real private keys, production certificates, or sensitive backend
addresses in public issues.

## Security Model

Dockistrate is intended for high-privilege operators managing local Docker and
Nginx state. Its primary security boundaries are command/config injection
prevention, path traversal prevention, safe filesystem mutation, and avoiding
accidental exposure of generated private key material.

See `docs/security/threat-model.md` for the project threat model.
