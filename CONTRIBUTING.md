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
Linux. Runtime workflows also use OpenSSL and standard Linux/macOS filesystem
tools with `/dev/fd`. The test suite additionally needs Python 3, `rsync`, and GNU
coreutils for its timeout launcher; on macOS, `gtimeout` is supplied by coreutils.
These test dependencies do not add a host Python requirement for operators.

The TLS keylog runtime regression needs a C compiler selected by `CC` or
available as `cc`. Its required ABI and permission fixture does not need OpenSSL
development headers; when those headers and libraries are available, it also
tests real TLS handshakes. Normal TLS decrypt capture builds its helper inside
the configured Nginx image and does not require a host compiler.

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

The default command runs every registered script and all four shards of each
integration suite sequentially. It preserves the original state tree and resets
an isolated tree between scripts; failures are reported without dropping later
coverage. Do not run multiple suites concurrently in one checkout.

Use `TEST_RUN_SUITE` for focused work:

| Suite | Coverage |
| --- | --- |
| `fast` | General unit and regression scripts |
| `domain-config` | Editable CSVs, migration, apply, recovery, certificates, and backup lifecycle |
| `persisted-render` | Persisted Nginx render matrix |
| `integration-cli` | All CLI integration shards |
| `integration-feature-configs` | All feature configuration integration shards |

The domain suite has two CI shards on Linux and four on native macOS Bash 3.
Run one Linux grouping locally with:

```bash
SKIP_DOCKER_CHECKS=true TEST_RUN_SUITE=domain-config \
  TEST_DOMAIN_SHARD_TOTAL=2 TEST_DOMAIN_SHARD_INDEX=0 ./tests/run.sh
```

Use indices `0` and `1` to cover both Linux shards. To reproduce the macOS
grouping, set `TEST_DOMAIN_SHARD_TOTAL=4`, use indices `0` through `3`, and invoke
`/bin/bash ./tests/run.sh` with native macOS Bash 3. Fast-suite sharding uses
`TEST_FAST_SHARD_TOTAL` and `TEST_FAST_SHARD_INDEX`; integration suites use
`TEST_SHARD_TOTAL` and `TEST_SHARD_INDEX`. These selectors cannot be combined.
Suite scripts are partitioned in registration order, so all shards together
run each selected script exactly once. The selectors do not leak into nested
runners.

CI retains its existing required fast-check names: those checks run even when
a domain shard fails and explicitly fail unless all domain shards for that
platform succeeded. Complete validation includes every suite listed above.
Job and per-script timeouts stay finite; cancellation must finish child cleanup
before restoring state. When diagnosing a slow run, use the printed per-script
elapsed times and slowest-script summary before adjusting a deadline.
See [test performance and coverage](docs/development/test-performance.md#local-runner-limits)
for local timeout defaults and overrides.

For networking, TLS, mTLS, ACL, header, or Nginx configuration changes, also run
targeted validations with real Docker in a disposable environment. Use the
affected [feature guide](docs/README.md) to check actual responses, negotiated
connections, accepted and rejected requests, and recovery. Mocked CI does not
replace those checks. Record the tested revision, commands, results and any
unavailable external prerequisites in the pull request.

For focused changes to runtime path helpers, run
`bash tests/runtime_path_assignment.sh` and `bash tests/literal_path_identity.sh`.
The first checks literal bytes and caller shell state; the second checks
filesystem guards. Both also run in the full suite.

## Documentation And UX

Follow the [interactive documentation contract](docs/development/interactive-documentation.md)
when changing operator guides, screenshots, or menu coverage. Validate with
`python3 scripts/docs/check_documentation.py`. Capture tooling is a development
dependency; it does not change operator requirements.

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
