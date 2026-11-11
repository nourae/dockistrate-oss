# Test performance and coverage

Performance work must reduce repeated work while keeping the scenarios that
protect runtime behavior. Dockistrate's tests invoke the real CLI in separate
Bash processes with isolated state and lightweight Docker mocks. Production
commands and the interactive picker share the same loaders and utility helpers.

## Runtime and fixture improvements

- Compute pure lexical runtime path results in Bash instead of command
  substitutions. Filesystem containment, symlink and identity checks still run
  on every operation; there is no persistent filesystem cache.
- Extract module filenames with Bash expansion. Module order, exclusions,
  direct sourcing and physical loader-directory resolution remain unchanged.
- Quote CSV row fields in the caller's process. The public field formatter and
  the encoded CSV format remain unchanged, including embedded quotes/newlines.
- Split ordinary absolute file paths in Bash. Root, relative paths, repeated
  separators and trailing separators retain the existing utility fallback.
  Guard checks, permissions, atomic replacement and rollback remain unchanged.
- Visit byte-identical private runtime file paths once per permission operation.
  Keep GNU `stat` on its direct path and remember a successful BSD syntax choice
  while reading fresh metadata for every check. Path and working-directory changes,
  function overrides, and failed calls retain portable fallback behavior.
- Restore private, same-run state snapshots between independent scenarios in
  the long ACL and port-reconciliation cases. All original CLI commands and
  assertions remain. Unrelated
  state is checked before each restore, and rollback scenarios keep their
  complete transitions.
- Limit the focused TLS permission test to its certificate fixture. The same
  TLS file assertions also run in the existing default-root permission-repair
  integration case, preserving coverage without a second whole-checkout repair.

These are internal changes shared by CLI and interactive mode. They introduce
no command, prompt, completion, state-format or image-default changes and retain
macOS Bash 3 support.

## CI feedback

Domain-configuration tests run in two shards on Linux and four on native macOS
Bash 3 before their platform's syntax and fast checks. Every registered domain
script runs exactly once, with its existing per-script deadline. Maintainer CI
retains its 25-minute Linux and 35-minute macOS domain job budgets, and 25-minute
syntax/fast job budgets. Public GitHub-hosted domain and syntax/fast jobs each
have a 60-minute cumulative budget. Release validation hit the former 25-minute
Linux and 35-minute macOS domain limits, then the 25-minute syntax/fast limits
on both platforms.
These domain and syntax/fast job adjustments change no individual test deadline,
shard count, assertion or cancellation handling. Public CI still has 26 runtime
checks and one documentation check.
The fast checks run even if a domain shard fails,
and propagate domain-suite failures into their required check result. Integration
jobs wait for their platform's fast checks; Linux's persisted-render job also
waits for its Linux fast check. A failed script still allows the remaining tests
in that runner to report diagnostics; cancellation stops remaining work.
Each platform progresses without waiting for the other platform.

The public persisted-render matrix uses a 1,800-second limit, with a 35-minute
job budget for setup and cleanup. After reaching its former 600-second cap, a
hosted run passed in 1,159 seconds, leaving only 41 seconds below the interim
1,200-second limit. Maintainer CI retains its 600-second limit and 15-minute job
budget; the local default remains 1,200 seconds. All matrix cases and assertions
remain enabled.

Public feature-configuration shards use a 3,600-second limit and a 65-minute job
budget on both platforms. Hosted shards passed all 34 cases in 2,129 seconds on
Linux and 2,331 seconds on macOS, leaving 271 and 69 seconds below the former
limit. Maintainer feature shards retain 2,400 seconds and 45 minutes; CLI shards
retain 1,800 seconds and 35 minutes. Other individual limits and all test coverage
are unchanged.

Run real Docker validation separately from mocked regression tests, using a
disposable environment and the affected feature's verification instructions.
Independent jobs need separate checkouts and state; concurrent suites must not
share a mutable checkout. Preserve all required suites and per-test limits
when changing job scheduling. See [validation guidance](../../CONTRIBUTING.md#validation).

Regular CI uses native system Bash on macOS and four shards per integration
suite/platform. Public CI uses GitHub-hosted Linux and macOS runners. Syntax and
fast checks continue to enforce the domain-suite result. Scheduling prioritizes
fast feedback; it does
not by itself reduce the amount of passing test work. Measure first-result
latency separately from test execution time.

## Local Runner Limits

The default runner executes every registered script and all four shards of each
integration suite sequentially. It restores the original state after completion;
do not run concurrent suites in the same checkout. Selectors and shard commands
are documented in [Contributing](../../CONTRIBUTING.md#validation).

Local per-script limits in `tests/run.sh` are failure bounds, not expected runtimes:

| Script group | Default seconds | Override |
| --- | ---: | --- |
| Ordinary tests | 90 | `TEST_TIMEOUT_SECONDS` |
| Marked slow tests | 240 | `TEST_TIMEOUT_SLOW_SECONDS` |
| Marked domain configuration tests | 600 | `TEST_TIMEOUT_DOMAIN_CONFIG_SECONDS` |
| Marked domain recovery tests | 1,200 | `TEST_TIMEOUT_DOMAIN_RECOVERY_SECONDS` |
| Persisted-render matrix | 1,200 | `TEST_TIMEOUT_PERSISTED_RENDER_SECONDS` |
| Each CLI integration shard | 1,800 | `TEST_TIMEOUT_INTEGRATION_SECONDS` |
| Each feature-config integration shard | 2,400 | `TEST_TIMEOUT_INTEGRATION_SECONDS` |

The integration override applies to both selected integration suites. The
termination grace period is `TEST_TIMEOUT_GRACE_SECONDS`, defaulting to five
seconds. CI sets its own checked-in limits; local overrides do not change those
workflows. A failed or timed-out script makes the runner fail even if later
scripts pass. Cancellation stops descendants before restoring the saved state.

## Repeating measurements

Use separate disposable checkouts of the two revisions on the same machine.
Keep the shell, filesystem, tools, mocks and environment identical. Run one
measurement at a time; alternate revision order and take at least three samples
before comparing medians and ranges. Start each sequence with fresh private
state. Do not time tracing or profiling as a normal sample.

Run the full suite without timeout overrides:

```bash
time env SKIP_DOCKER_CHECKS=true ./tests/run.sh
```

The timeout launcher requires GNU coreutils and recognizes `timeout`, `gtimeout`
and `gnutimeout`, checking each tool's version before selecting it. This supports
systems whose default `timeout` comes from another implementation without
changing the suite's timeout or cancellation behavior.

For a shorter representative sample in each disposable checkout, run the whole
existing add-backend integration case:

```bash
time env SKIP_DOCKER_CHECKS=true /bin/bash tests/integration/test_cli.sh -- \
  test_add_backend_creates_records_and_configs
```

Use the selected Bash executable consistently, including child commands resolved
through `PATH`. On macOS, use `/bin/bash` to exercise native Bash 3. Record the
exact revision, shell/tool versions, exit status and complete test output.
Require each expected case exactly once and no skips, failures or timeouts;
a short duration alone is not a successful result.

Compare full-suite and CI times separately. CI test-step duration excludes
queueing, checkout and dependency setup. Sum shards only when describing total
test work; workflow wall time and first-result time are separate measurements.
One before/after CI observation is useful evidence, not a guaranteed speedup.

## Constraints

Do not speed up tests by omitting CLI entry points, replacing runtime validators,
skipping transactions, weakening assertions or shortening failure cleanup. State
reuse must be private to one test run and preserve cross-entity and rollback
checks. Copies must not share writable files with another scenario.

Extra shards do not reduce serial work on a single runner. Additional workers
require independent checkouts, state, mocks and temporary directories, plus
measured spare CPU and memory. Keep the existing native deadlines while
optimizing; any separate deadline change needs its own runtime evidence.

## Candidate decisions

The completion pass compared the already optimized revision `9ac26a4` with the
additional loader, CSV and path-splitting changes in `52d05b0`. Three alternating
pairs per shell/scenario on one Linux host produced these medians (seconds):

| Scenario | Bash 3 before → after | Bash 5 before → after |
| --- | --- | --- |
| Fresh status | 5.060 → 2.186 | 4.720 → 1.999 |
| Warm status | 3.912 → 1.647 | 3.292 → 1.418 |
| Complete add-backend integration case | 9.026 → 5.804 | 8.351 → 5.448 |

All 36 samples passed. These measure representative commands, not the complete
suite or native macOS. The add-backend ranges were 8.774–9.489 → 5.691–5.922
seconds on Bash 3 and 7.288–9.361 → 5.201–5.860 on Bash 5. Diagnostic tracing is
excluded from these measurements. These historical development measurements
are not validation of a later release; record current full-suite and native
CI results with each proposed change.

A separate add-backend process trace counted 1,963 → 1,270 child processes and
996 → 567 external executions. The sample still performed all 40 checksum-tool
and 85 `stat` executions, along with the same archive and permission operations.
The reduction comes from pure string work; trace durations are not benchmark
samples.

A lowercase-ASCII shortcut for domain normalization was rejected: replacing its
pipeline with a direct `printf` changed native closed-output return behavior.
The existing normalization implementation remains intact. Removing checksum
formatting processes is also deferred: preserving each supported tool's output
format, per-line parsing and partial-failure semantics requires more change than
this small residual target justifies. Every real checksum operation is retained.

The persisted-render suite already has only 20 state resets around 77 CLI
invocations. Reusing an initialized state would affect bootstrap coverage and
carry mock/transaction metadata, while covering only a small part of the suite.
Keep its independent setups and all 24 backend creations; the shared production
improvements apply to them. Docker mock parsing and broad renderer/transaction
rewrites are not justified by the existing profile. Revisit those only with
measured residual cost, preserving the constraints above.

A directive-cleanup snapshot candidate was rejected after one paired run per
shell saved only 5.8 seconds on Bash 3 and 8.3 seconds on Bash 5 (about 3–4%).
Most removal scenarios already clean up their own state; this small gain did
not justify another snapshot lifecycle. The original cleanup fixture remains.

The dedicated-host fallback snapshot candidate was also rejected. It saved
13.3 seconds on Bash 3 and 5.2 seconds on Bash 5 in the same paired comparison,
but required another 52 lines of fixture lifecycle and sentinel checks. Keep
the original scenario flow; retain the simpler TLS fixture optimization.
