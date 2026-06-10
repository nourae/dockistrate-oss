# Contributing

Thanks for helping improve Dockistrate. The project is a Bash-based operator
tool for managing Docker backends behind Nginx, so changes should preserve
macOS Bash 3 compatibility and Linux behavior.

## Setup

Clone the repository and run commands from the repository root:

```bash
./dockistrate.sh --version
```

For local Docker validation, install Docker Desktop on macOS or Docker Engine on
Linux. macOS test runs also need GNU coreutils so `gtimeout` is available.

## Development Principles

- Use Dockistrate commands for supported backend, proxy, port, TLS, ACL,
  backup, restore, and diagnostic operations.
- Preserve both CLI and interactive support for user-facing behavior unless the
  change is explicitly scoped to one mode.
- Keep Bash 3 portability: avoid associative arrays, guard strict-mode
  expansions, and use existing portability helpers.
- Treat config/state mutations as transactional workflows where the existing
  codebase does so.
- Do not commit runtime state, private keys, generated certificates, logs, or
  local backups.

## Validation

Run the mocked regression suite before opening a pull request:

```bash
SKIP_DOCKER_CHECKS=true ./tests/run.sh
```

For networking, TLS, mTLS, ACL, header, or Nginx configuration changes, also run
targeted validations for the affected behavior.

## Documentation And UX

User-facing behavior changes should keep these surfaces in sync:

- CLI dispatch, argument specs, choices, usage text, and command descriptions.
- Interactive picker visibility and prompt flow.
- Bash completion.
- `README.md`, `docs/function-reference.md`, and the rendered
  `docs/function-reference.html` when command behavior changes.

If a change has no user-visible surface impact, say so in the pull request.

## Pull Requests

Each pull request should include:

- Purpose and summary of changes.
- Mode scope: `both`, `CLI-only`, `interactive-only`, or
  `no user-visible surface`.
- Validation commands run and any skipped checks with rationale.
- Notes for docs, completion, security-sensitive behavior, and runtime state
  cleanup where relevant.
