#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Exercise the real runner and selector in an isolated tree. Integration bodies
# are replaced with cheap registrations, so this checks orchestration without
# running a second integration suite inside the full regression suite.
exec python3 - "$ROOT_DIR" "$BASH" <<'PY'
from collections import Counter
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
bash = sys.argv[2]


def cancel_regression(received_signal, _frame):
    # Raising here unwinds the active fixture's finally block. A direct default
    # SIGTERM exit would strand its intentionally separate process session.
    raise SystemExit(128 + received_signal)


signal.signal(signal.SIGTERM, cancel_regression)
signal.signal(signal.SIGINT, cancel_regression)

scripts = re.findall(r'^  "(tests/[^"]+)"$', (root / "tests/run.sh").read_text(), re.M)
integration = {
    "tests/integration/test_cli.sh": ("integration-cli", 1800),
    "tests/integration/test_feature_configs.sh": ("integration-feature-configs", 2400),
}
inventories = {}
for script in integration:
    # Source declarations only, exactly as the integration entrypoints do, and
    # ask Bash for the current inventory instead of maintaining a second list.
    result = subprocess.run(
        [bash, "-eu", "-c", '''ROOT_DIR="$1"
for test_file in "$2"/*.sh; do source "$test_file"; done
declare -F | awk '{print $3}' | grep '^test_' | sort
''', "inventory", str(root), str(root / (script[:-3] + ".d"))],
        text=True, capture_output=True, check=True)
    inventories[script] = result.stdout.splitlines()
    assert inventories[script], "Integration inventory is empty: " + script

base_env = {key: value for key, value in os.environ.items()
            if not key.startswith(("TEST_", "FIXTURE_", "DOCKISTRATE_TEST_STATE_SANDBOX"))}
base_env.pop("BASH_ENV", None)
base_env.pop("ENV", None)

timeout_fixture = r'''#!/usr/bin/env bash
set -Eeuo pipefail
[ "${1:-}" != --probe ] || exit 0
printf '%s\t%s\n' "$1" "$3" >>"$FIXTURE_INVOCATIONS"
if [ "$3" = "${FIXTURE_TIMEOUT_LABEL:-}" ]; then exit 124; fi
shift 4
exec "$@"
'''

integration_fixture = r'''
# The real shunit entrypoints leave errexit disabled while selecting tests.
set +e
source ./tests/integration/helpers.d/shunit_suite.sh
function suite_addTest() {
  printf '%s\t%s\t%s\n' "$fixture_suite" "${TEST_SHARD_INDEX:-all}" "$1" >>"$FIXTURE_SELECTIONS"
}
if [ -e state/previous-shard ]; then exit 65; fi
printf 'temporary state\n' >state/previous-shard
integration_shunit_suite_add_tests "$fixture_suite" || exit 2
set -e
if [ "${TEST_SHARD_INDEX:-}" = "${FIXTURE_CANCEL_SHARD:-none}" ]; then
  sleep 60 &
  fixture_child=$!
  trap 'kill -TERM "$fixture_child" 2>/dev/null || true; wait "$fixture_child" 2>/dev/null || true; exit 143' TERM
  printf '%s\n' "$fixture_child" >"$FIXTURE_READY"
  wait "$fixture_child"
fi
if [ "${TEST_SHARD_INDEX:-}" = "${FIXTURE_FAIL_SHARD:-none}" ]; then exit 23; fi
'''

checks = 0
def session_members(session):
    members = []
    output = subprocess.check_output(["ps", "-e", "-o", "pid="], text=True)
    for value in output.split():
        pid = int(value)
        try:
            if os.getsid(pid) == session:
                members.append(pid)
        except ProcessLookupError:
            pass
    return members


def run_case(label, overrides=None, expected=0, cancel=False):
    global checks
    with tempfile.TemporaryDirectory(prefix="dockistrate-runner-shards-") as directory:
        tree = Path(directory)
        for path in ("tests/run.sh", "tests/lib/state_sandbox.sh",
                     "tests/integration/helpers.d/shunit_suite.sh"):
            destination = tree / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / path, destination)
        (tree / "dockistrate.sh").write_text("#!/usr/bin/env bash\nexit 0\n")
        (tree / "dockistrate.sh").chmod(0o755)
        # Keep the optional OSS test enabled so the all-suite inventory is exact.
        (tree / "scripts").mkdir()
        helper = tree / "tests/lib/run_with_timeout.sh"
        helper.write_text(timeout_fixture)
        helper.chmod(0o755)
        for script in scripts:
            destination = tree / script
            destination.parent.mkdir(parents=True, exist_ok=True)
            text = "#!/usr/bin/env bash\nset -Eeuo pipefail\n"
            if script in integration:
                text += 'fixture_suite="%s"\n' % integration[script][0]
                text += "\n".join("function %s() { :; }" % name
                                   for name in inventories[script]) + "\n"
                text += integration_fixture
            else:
                text += "exit 0\n"
            destination.write_text(text)
            # Resolve non-executable scripts through the interpreter under test.
            destination.chmod(0o644)
        (tree / "bin").mkdir()
        (tree / "bin/bash").symlink_to(bash)
        (tree / "state").mkdir()
        original = tree / "state/original"
        original.write_text("original state\n")
        original.chmod(0o640)
        identity = original.stat()
        env = dict(base_env, PATH=str(tree / "bin") + os.pathsep + base_env["PATH"],
                   FIXTURE_INVOCATIONS=str(tree / "invocations"),
                   FIXTURE_SELECTIONS=str(tree / "selections"),
                   FIXTURE_READY=str(tree / "ready"))
        env.update(overrides or {})
        with (tree / "output").open("w") as output:
            process = subprocess.Popen([bash, "tests/run.sh"], cwd=tree, env=env,
                                       stdout=output, stderr=output, start_new_session=True)
            try:
                if cancel:
                    deadline = time.monotonic() + 10
                    while not (tree / "ready").exists():
                        assert process.poll() is None, "Runner exited before cancellation"
                        assert time.monotonic() < deadline, "Cancellation fixture not ready"
                        time.sleep(0.02)
                    process.send_signal(signal.SIGTERM)
                # The all-suite fixture launches the entire growing script
                # inventory even though each body is cheap. Allow its process
                # startup overhead on a shared single-CPU host; keep focused
                # cancellation/selection observations at the original bound.
                observation_seconds = 60 if overrides is None else 30
                try:
                    result = process.wait(timeout=observation_seconds)
                except subprocess.TimeoutExpired as error:
                    tail = "\n".join((tree / "output").read_text().splitlines()[-30:])
                    raise AssertionError("%s: observer timed out after %ss\n%s" % (
                        label, observation_seconds, tail)) from error
                assert not session_members(process.pid), label + ": a shard descendant survived"
            finally:
                # The runner places each helper in its own process group. The
                # fixture's new session, not just its leader's group, owns all
                # these descendants, even when the runner has already exited.
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    members = session_members(process.pid)
                    for pid in members:
                        try:
                            if os.getsid(pid) == process.pid:
                                os.kill(pid, sig)
                        except ProcessLookupError:
                            pass
                    if members and sig == signal.SIGTERM:
                        time.sleep(0.3)
                process.wait(timeout=5)
        output = (tree / "output").read_text()
        assert result == expected, "%s: status %s, expected %s\n%s" % (
            label, result, expected, "\n".join(output.splitlines()[-100:]))
        if cancel:
            child = int((tree / "ready").read_text())
            try:
                os.kill(child, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError(label + ": canceled shard child survived")
        restored = original.stat()
        assert (restored.st_ino, restored.st_mode, restored.st_mtime_ns, original.read_text()) == (
            identity.st_ino, identity.st_mode, identity.st_mtime_ns, "original state\n"), label + ": original state changed"
        assert list((tree / "state").iterdir()) == [original], label + ": temporary state survived"
        rows = [line.split("\t") for line in (tree / "invocations").read_text().splitlines()]
        selected = tree / "selections"
        selections = [line.split("\t") for line in selected.read_text().splitlines()] if selected.exists() else []
        checks += 1
        print("[runner-shards] PASS " + label)
        return rows, selections


rows, selected = run_case("default all-suite coverage")
ordinary = [script for script in scripts if script not in integration]
assert Counter(label for _, label in rows if " shard " not in label) == Counter(ordinary)
assert ["1200", "tests/persisted_render_validation.sh"] in rows
for script, (suite, budget) in integration.items():
    assert [(seconds, label) for seconds, label in rows if label.startswith(script)] == [
        (str(budget), "%s shard %s/4" % (script, index)) for index in range(4)]
    assert Counter(name for found, _, name in selected if found == suite) == Counter(inventories[script])
    assert all(sum(found == suite and index == str(shard) for found, index, _ in selected) > 0
               for shard in range(4))

rows, selected = run_case("suite and timeout overrides", {
    "TEST_RUN_SUITE": "integration-cli", "TEST_TIMEOUT_INTEGRATION_SECONDS": "17"})
assert len(rows) == 4 and all(seconds == "17" for seconds, _ in rows)
assert Counter(name for _, _, name in selected) == Counter(inventories["tests/integration/test_cli.sh"])

rows, selected = run_case("explicit CI shard runs once", {
    "TEST_RUN_SUITE": "integration-feature-configs", "TEST_SHARD_TOTAL": "4",
    "TEST_SHARD_INDEX": "2", "TEST_TIMEOUT_INTEGRATION_SECONDS": "19"})
assert rows == [["19", "tests/integration/test_feature_configs.sh shard 2/4"]]
assert [name for _, _, name in selected] == inventories["tests/integration/test_feature_configs.sh"][2::4]

# The manual release gate uses smaller groups than the local four-shard run.
# Exercise the actual selector for all eight groups, preserving every case once.
for script, (suite, budget) in integration.items():
    gate_selections = []
    for index in range(8):
        rows, selected = run_case("release gate %s shard %s/8" % (suite, index), {
            "TEST_RUN_SUITE": suite, "TEST_SHARD_TOTAL": "8",
            "TEST_SHARD_INDEX": str(index), "TEST_TIMEOUT_INTEGRATION_SECONDS": str(budget)})
        assert rows == [[str(budget), "%s shard %s/8" % (script, index)]]
        gate_selections.extend(name for _, _, name in selected)
    assert Counter(gate_selections) == Counter(inventories[script])

rows, selected = run_case("explicit one-shard full coverage", {
    "TEST_RUN_SUITE": "integration-cli", "TEST_SHARD_TOTAL": "1", "TEST_SHARD_INDEX": "0"})
assert len(rows) == 1
assert Counter(name for _, _, name in selected) == Counter(inventories["tests/integration/test_cli.sh"])

for name, variables in (
    ("missing index", {"TEST_SHARD_TOTAL": "4"}),
    ("missing total", {"TEST_SHARD_INDEX": "0"}),
    ("zero total", {"TEST_SHARD_TOTAL": "0", "TEST_SHARD_INDEX": "0"}),
    ("invalid index", {"TEST_SHARD_TOTAL": "4", "TEST_SHARD_INDEX": "oops"}),
    ("out-of-range index", {"TEST_SHARD_TOTAL": "4", "TEST_SHARD_INDEX": "4"}),
):
    rows, selected = run_case(name, dict(variables, TEST_RUN_SUITE="integration-cli"), expected=1)
    assert len(rows) == 1 and not selected, name + ": invalid shard selected cases"

rows, selected = run_case("failed shard preserves later coverage", {
    "TEST_RUN_SUITE": "integration-cli", "FIXTURE_FAIL_SHARD": "1"}, expected=1)
assert len(rows) == 4
assert Counter(name for _, _, name in selected) == Counter(inventories["tests/integration/test_cli.sh"])

rows, selected = run_case("timeout status fails and later shards run", {
    "TEST_RUN_SUITE": "integration-feature-configs",
    "FIXTURE_TIMEOUT_LABEL": "tests/integration/test_feature_configs.sh shard 1/4"}, expected=1)
assert len(rows) == 4 and {index for _, index, _ in selected} == {"0", "2", "3"}

rows, selected = run_case("cancellation stops later shards", {
    "TEST_RUN_SUITE": "integration-cli", "FIXTURE_CANCEL_SHARD": "1"}, expected=143, cancel=True)
assert len(rows) == 2 and {index for _, index, _ in selected} == {"0", "1"}

rows, selected = run_case("persisted override unchanged", {
    "TEST_RUN_SUITE": "persisted-render", "TEST_TIMEOUT_PERSISTED_RENDER_SECONDS": "600"})
assert rows == [["600", "tests/persisted_render_validation.sh"]] and not selected
print("[runner-shards] %s orchestration cases passed; CLI %s and feature %s cases covered exactly once." % (
    checks, len(inventories["tests/integration/test_cli.sh"]),
    len(inventories["tests/integration/test_feature_configs.sh"])))
PY
