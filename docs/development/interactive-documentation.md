# Maintaining interactive documentation

The operator guides explain actual interactive behavior. The function reference
retains implementation detail. Capture tools are development dependencies and do
not add Python, X11, or image-processing requirements to Dockistrate itself.

## Authoring contract

Keep the README between 600 and 800 words with Home, review, and verification
screens. Put complete workflows in the existing subject guides. Each command
has one canonical `cmd-<command>` anchor; related operations may share a table
and common navigation. Keep old public headings as reference sections or links
when moving material to another guide.

Explain purpose, prerequisites, exact inputs, review or confirmation, result,
verification, and undo when appropriate. A menu screenshot alone does not
explain a workflow. Include every distinct prompt needed to follow it, with one
or two sentences next to each screenshot. Read-only commands do not acquire an
invented Run step. Include copyable values and text alternatives.

The [coverage inventory](../interactive-coverage.json) maps commands and Home
features to guides, assets, and verification evidence. Update it when commands
or journeys change. A `not-live-verified` record needs a concrete limitation;
its guide must label the ending as expected rather than observed.

## Capture environment

Maintainers record live walkthroughs on disposable GitHub-hosted Linux VMs.
Each scenario has its own Docker daemon, networking, clean checkout, and demo
state. The public repository includes capture source and committed evidence,
but does not include or automatically run the maintainer capture workflow.
The driver requires a GitHub-hosted runner, refuses a daemon containing
containers, and refuses ordinary operator hosts. Do not bypass those checks to
run live capture locally. Capture setup uses the checked-out source unchanged.

The driver and archive tests can run locally without live Docker or screenshots:

```bash
cd scripts/docs
python3 -m unittest capture.test_driver capture.test_evidence_archive -v
```

These tests check the capture tooling; they do not verify a running application.

The capture entry point is `scripts/docs/capture_interactive.py`. Scenario
modules share the driver under `scripts/docs/capture/`. Provisioning the capture
VM, pulling/building fixture images, and inspecting containers are development
setup operations; manage demo backends, proxy configuration, and networks using
Dockistrate whenever it supports the operation.

Use neutral demonstration values such as `example.com` and a neutral working
directory. Never copy production state into a capture. Deletion and uninstall
belong at the end of their own disposable scenarios. Check an unrelated sentinel
resource where cleanup scope is being demonstrated.

## Capture fidelity and evidence

Capture the real interactive program through a PTY. The same unmodified output
bytes feed a live terminal display; its window produces each PNG. Set consistent
terminal size, font, theme, and locale. Move the actual selection before capturing
it. Do not paint replacement values, remove warnings, or synthesize success.

Keep source revision, environment and image versions, original terminal bytes,
input events, exit status, selected PNGs, text alternatives, and verification
outputs together. Only selected safe images, text, and provenance belong in
`docs/assets/interactive/`; raw runtime state and certificate/key material do not.
Import successful workflow artifacts with `scripts/docs/import_captures.py`.
It verifies source compatibility and every image/text hash, selects the screens
used by the guides, and packs original terminal recordings and verification
evidence into one `*-recordings.tar.gz` archive per scenario. The matching
`*-provenance.json` records the archive/member hashes and each screenshot's
terminal byte offset. Certificate material is excluded from non-terminal
verification logs; the original terminal recordings and selected screen pixels
remain unchanged. Workflow artifacts retain the complete capture run for review.

To refresh selected groups, pass only their successful artifacts to the importer.
It replaces those scenarios and preserves the other committed captures, including
journeys that share a walkthrough or command. Use `--allow-partial` while initially
building coverage if some commands still need their first capture. Existing
provenance and recordings remain necessary when updating only part of a guide.
The importer rejects a refresh before writing if it removes an already captured
command result, lacks a required insertion marker, or leaves references to
screenshots or transcripts it would delete.
Only supported capture groups are accepted, and each group may replace only its
own assets. Inputs and output paths are checked before any file changes,
including links that could redirect writes or cleanup outside their destination.
New captures must match the checked-out runtime; preserved groups keep their
original source revisions. This does not re-verify them against later runtime
edits: recapture any group whose prompts, behavior, or results changed.

To inspect a committed recording, unpack its archive into a new temporary
directory, then locate the `pty_log` member named by the provenance. The plain
text link beside each image remains the convenient reading alternative.

Verify a feature with an observable result: requests for routes and headers,
payloads for stream mappings, negotiated TLS and certificate identity, accepted
and rejected access decisions, or a before/after state comparison for restore.
Configuration syntax alone does not establish connectivity or access control.

Genuine public certificate issuance needs a controlled hostname, DNS and ACME
reachability. If those are missing, capture the available inputs and review,
then label the ending **not live verified** and explain the prerequisite.
An empty renewal or mock issuer is not evidence of successful renewal.

## Validate a change

Regenerate both function-reference files after moving source declarations:
run `./scripts/update-function-reference-appendices.sh` followed by
`./scripts/render-function-reference-html.sh`. The generated source index links
to declaration lines, and documentation CI checks those links after library or
entrypoint changes.

```bash
python3 scripts/docs/check_documentation.py
python3 -m unittest discover -s tests -p 'documentation_*.py'
./scripts/render-function-reference-html.sh
SKIP_DOCKER_CHECKS=true ./tests/run.sh
```

The checker derives menu coverage from source and checks guide anchors, local
links, images, text alternatives, verification status, hashes, and corresponding
original recording offsets for every retained capture, including verification
screens outside command and navigation coverage rows. Documentation screenshots
must have retained provenance. Archive validation does not extract files. Its
`--allow-pending-captures` option is for local authoring only; CI requires
completed capture records or explicit external-verification limitations.

Review the rendered README and every changed guide at desktop and narrow widths.
Open full-size images and check text alternatives. Re-run the affected capture
scenarios when prompts or behavior change; wording-only edits do not require a
full live rerun. Check meaningful text and outcomes rather than pixel equality.

Stage new assets before checking a public export: the exporter reads Git's index.
Run the source checkout’s documented export validation command in check-only mode.
Inspect a disposable exported tree with the same documentation checker. This
checks export readiness without publishing or changing the public repository.
