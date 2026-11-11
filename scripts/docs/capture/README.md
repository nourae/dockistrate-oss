# Maintaining interactive documentation captures

This directory contains the capture driver, scenarios and evidence tools used
for the published walkthroughs. Dockistrate itself retains its Bash-only runtime.
The maintainer runs live captures in a separate private workflow on disposable
GitHub-hosted Linux VMs. That workflow is not included in this public repository
and does not run on public pull requests. Public CI validates the committed
documentation and evidence with the regular runtime and documentation checks.

## Live capture requirements

Live capture requires a fresh GitHub-hosted Linux VM with an empty Docker daemon,
a checkout without `state/`, and free TCP ports 80/443 and UDP port 443. Do not
bypass the executable's environment checks or run it against an operator's
Docker environment. Ask the maintainer to recapture affected workflows when a
change affects a documented prompt, choice or outcome.

There are 22 independent capture groups across `core`, `security` and
`operations`. Each group uses a separate disposable VM. Scenario modules declare
the journeys and their verification; the matrix helper selects valid groups.
The entry point used inside a prepared hosted VM is:

```bash
cd /opt/dockistrate-demo
python3 scripts/docs/capture_interactive.py --scenario core --group all --output /opt/dockistrate-demo-artifacts
```

The driver executes the actual `./dockistrate.sh -i` in a PTY and sends its bytes
to a real xterm window under Xvfb. ImageMagick captures that window after the
recorded navigation. Long output uses real xterm scrollback. Captures retain
keystrokes, original PTY bytes, output transcripts, exit codes, source revision
and verification results. Background trimming is lossless; displayed messages
are not rewritten or composed from invented terminal text.

Fixtures use demonstration domains and self-signed local HTTPS. Public ACME
issuance requires a separately configured real domain and is not implied by the
captures. Docker image pulls provision fixture images; supported backend,
proxy, network and configuration operations use Dockistrate commands.

## Local tooling checks

The driver protocol can be tested locally without initializing runtime state:

```bash
cd scripts/docs
python3 -m unittest capture.test_driver capture.test_evidence_archive -v
```

These tests exercise real Bash menu/search/readline functions in a PTY. They
verify the driver protocol, do not generate new screenshots, and do not replace
live Docker validation. From the repository root, validate the published
documentation with:

```bash
python3 scripts/docs/check_documentation.py --public-export
```

## Original evidence

Each journey has PNG screenshots and TXT transcripts under
`docs/assets/interactive/`. Provenance records associate them with the source
revision, command, terminal position and SHA-256 digests. Recording archives
retain the original PTY bytes and verification evidence. Repeated observations
receive unique session suffixes. Failed journeys remain marked failed.

The importer checks runtime compatibility with the recorded source revision;
the documentation checker verifies evidence integrity. Unaffected workflows may
retain their pinned captures, but these tools do not decide whether a later
behavior change needs a recapture. Preserve the existing screenshot, transcript,
provenance and archive together.

`capture.evidence_archive` creates deterministic archives from already sanitized
evidence. Its readers validate members in memory without extracting files.
Packing performs no redaction. Raw runtime state, real private keys, backup
archives, packet captures and TLS key logs are not documentation assets. Only
disposable demonstration credentials belong in capture fixtures; hidden-input
events are redacted before evidence is retained.
