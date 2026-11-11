#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Run the actual scheduler with harmless scripts, real state preservation and
# an observable timeout boundary. No second regression suite runs inside this.
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

root, bash = Path(sys.argv[1]), sys.argv[2]
runner = (root / "tests/run.sh").read_text()
scripts = re.findall(r'^  "(tests/[^"]+)"$', runner, re.M)
excluded = {"tests/persisted_render_validation.sh", "tests/integration/test_cli.sh",
            "tests/integration/test_feature_configs.sh"}
domain = [script for script in scripts if script.startswith(("tests/domain_config_", "tests/domain_csv_")) or
          script in {"tests/shared_csv_records.sh",
                     "tests/nginx_certificate_projection_domains.sh"}]
fast = [script for script in scripts if script not in excluded and script not in domain]
assert domain and not set(fast) & set(domain)
assert set(fast + domain) == set(scripts) - excluded, "Suite split loses standalone coverage"
assert fast and len(scripts) == len(set(scripts)), "Runner inventory is empty or duplicated"
base_env = {key: value for key, value in os.environ.items()
            if not key.startswith(("TEST_", "FIXTURE_", "DOCKISTRATE_TEST_STATE_SANDBOX"))
            and key not in ("BASH_ENV", "ENV")}

timeout_fixture = r'''#!/usr/bin/env bash
set -Eeuo pipefail
[ "${1:-}" != --probe ] || exit 0
printf '%s\t%s\n' "$1" "$3" >>"$FIXTURE_INVOCATIONS"
label="$3"
shift 4
if [ "$label" = "${FIXTURE_FAIL_LABEL:-}" ]; then exit 23; fi
if [ "$label" = "${FIXTURE_TIMEOUT_LABEL:-}" ]; then exit 124; fi
if [ "$label" = "${FIXTURE_CANCEL_LABEL:-}" ]; then
  sleep 60 &
  fixture_child=$!
  function cleanup_cancelled_fixture() {
    # The runner sends TERM from both cancellation and EXIT cleanup.
    trap '' INT TERM
    kill -TERM "$fixture_child" 2>/dev/null || true
    while ! wait "$fixture_child" 2>/dev/null; do
      kill -0 "$fixture_child" 2>/dev/null || break
    done
    exit 143
  }
  trap cleanup_cancelled_fixture TERM
  printf '%s\n' "$fixture_child" >"$FIXTURE_READY"
  wait "$fixture_child"
fi
exec "$@"
'''

script_fixture = r'''#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${TEST_FAST_SHARD_TOTAL+x}" = x ] || [ "${TEST_FAST_SHARD_INDEX+x}" = x ] ||
  [ "${TEST_DOMAIN_SHARD_TOTAL+x}" = x ] || [ "${TEST_DOMAIN_SHARD_INDEX+x}" = x ]; then
  echo 'Suite selectors leaked into a child test' >&2
  exit 66
fi
if [ "$0" = "${FIXTURE_NESTED_TRIGGER:-}" ]; then
  (
    cd "$FIXTURE_NESTED_TREE"
    export FIXTURE_INVOCATIONS="$FIXTURE_NESTED_INVOCATIONS"
    export FIXTURE_SANDBOX_HITS="$FIXTURE_NESTED_SANDBOX_HITS"
    # This nested runner owns a separate checkout, not its parent's state tree.
    unset FIXTURE_NESTED_TRIGGER DOCKISTRATE_TEST_STATE_SANDBOX_MANAGED_BY_RUNNER
    TEST_RUN_SUITE=integration-cli TEST_SHARD_TOTAL=4 TEST_SHARD_INDEX=0 "$BASH" tests/run.sh
  )
fi
'''

sandbox_observer = r'''
eval "$(declare -f dockistrate_test_state_sandbox | sed '1s/dockistrate_test_state_sandbox/_fixture_state_sandbox/')"
function dockistrate_test_state_sandbox() {
  printf 'entered\n' >>"$FIXTURE_SANDBOX_HITS"
  _fixture_state_sandbox "$@"
}
'''


def prepare_tree(tree, text, selected, env):
    (tree / "tests/lib").mkdir(parents=True)
    (tree / "tests/run.sh").write_text(text)
    (tree / "tests/lib/state_sandbox.sh").write_text(
        (root / "tests/lib/state_sandbox.sh").read_text() + sandbox_observer)
    helper = tree / "tests/lib/run_with_timeout.sh"
    helper.write_text(timeout_fixture)
    helper.chmod(0o755)
    (tree / "dockistrate.sh").write_text("#!/usr/bin/env bash\nexit 0\n")
    (tree / "dockistrate.sh").chmod(0o755)
    (tree / "scripts").mkdir()
    for name in selected:
        target = tree / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(script_fixture)
        target.chmod(0o644)
    (tree / "state").mkdir()
    original = tree / "state/original"
    original.write_text("preserved state\n")
    original.chmod(0o640)
    return original, original.stat()


def session_members(session):
    members = []
    for value in subprocess.check_output(["ps", "-e", "-o", "pid="], text=True).split():
        try:
            if os.getsid(int(value)) == session:
                members.append(int(value))
        except ProcessLookupError:
            pass
    return members


def cancelled(received, _frame):
    raise SystemExit(128 + received)


signal.signal(signal.SIGTERM, cancelled)
signal.signal(signal.SIGINT, cancelled)
checks = 0


def run_case(label, overrides=None, expected=0, cancel=False, invalid=False, nested=False, small=False):
    global checks
    with tempfile.TemporaryDirectory(prefix="dockistrate-fast-shards-") as directory:
        tree = Path(directory)
        (tree / "bin").mkdir()
        (tree / "bin/bash").symlink_to(bash)
        env = dict(base_env, PATH=str(tree / "bin") + os.pathsep + base_env["PATH"],
                   TEST_RUN_SUITE="fast", FIXTURE_INVOCATIONS=str(tree / "invocations"),
                   FIXTURE_SANDBOX_HITS=str(tree / "sandbox-hits"), FIXTURE_READY=str(tree / "ready"))
        env.update(overrides or {})
        fixture_scripts = [] if invalid else (domain if env["TEST_RUN_SUITE"] == "domain-config" else fast)
        fixture_runner = runner
        if small:
            # Full inventory coverage is checked above; failure/cancellation
            # behavior needs only a few scripts before and after the boundary.
            fixture_scripts = fixture_scripts[:small]
            fixture_runner, count = re.subn(r'(?ms)^scripts=\(\n.*?^\)',
                'scripts=(\n' + ''.join('  "' + name + '"\n' for name in fixture_scripts) + ')', runner)
            assert count == 1
        original, before = prepare_tree(tree, fixture_runner, fixture_scripts, env)
        if nested:
            nested_tree = tree / "nested"
            nested_text, count = re.subn(r'(?ms)^scripts=\(\n.*?^\)',
                'scripts=(\n  "tests/integration/test_cli.sh"\n)', runner)
            assert count == 1
            nested_original, nested_before = prepare_tree(
                nested_tree, nested_text, ["tests/integration/test_cli.sh"], env)
            env.update(FIXTURE_NESTED_TRIGGER=nested, FIXTURE_NESTED_TREE=str(nested_tree),
                       FIXTURE_NESTED_INVOCATIONS=str(tree / "nested-invocations"),
                       FIXTURE_NESTED_SANDBOX_HITS=str(tree / "nested-sandbox-hits"))
        with (tree / "output").open("w") as output:
            process = subprocess.Popen([bash, "tests/run.sh"], cwd=tree, env=env,
                stdout=output, stderr=output, start_new_session=True)
            try:
                if cancel:
                    deadline = time.monotonic() + 10
                    while not (tree / "ready").exists():
                        assert process.poll() is None, "Runner exited before cancellation"
                        assert time.monotonic() < deadline, "Cancellation fixture did not start"
                        time.sleep(0.02)
                    process.send_signal(signal.SIGTERM)
                status = process.wait(timeout=30)
                assert not session_members(process.pid), label + ": a descendant survived"
            finally:
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
        assert status == expected, "%s: exit %s instead of %s\n%s" % (label, status, expected, output[-5000:])
        after = original.stat()
        assert (before.st_ino, before.st_mode, before.st_mtime_ns) == (
            after.st_ino, after.st_mode, after.st_mtime_ns)
        assert original.read_text() == "preserved state\n"
        assert list((tree / "state").iterdir()) == [original]
        invocation_path = tree / "invocations"
        rows = [line.split("\t") for line in invocation_path.read_text().splitlines()] if invocation_path.exists() else []
        if invalid:
            assert not rows and not (tree / "sandbox-hits").exists(), "Invalid selector entered sandbox or ran a test"
        else:
            assert (tree / "sandbox-hits").read_text() == "entered\n"
        if nested:
            assert (tree / "nested-invocations").read_text() == "1800\ttests/integration/test_cli.sh shard 0/4\n"
            assert (tree / "nested-sandbox-hits").read_text() == "entered\n"
            nested_after = nested_original.stat()
            assert (nested_before.st_ino, nested_before.st_mode, nested_before.st_mtime_ns) == (
                nested_after.st_ino, nested_after.st_mode, nested_after.st_mtime_ns)
            assert nested_original.read_text() == "preserved state\n"
        if cancel:
            assert len(rows) == 1, "Canceled shard started another script"
            assert "[tests] Error:" not in output
        checks += 1
        print("[fast-runner-shards] PASS " + label)
        return rows


for suite, prefix, inventory, shard_counts in (("fast", "TEST_FAST", fast, (2,)),
                                               ("domain-config", "TEST_DOMAIN", domain, (2, 4))):
    whole = run_case(suite + " unsharded coverage in registration order", {"TEST_RUN_SUITE": suite})
    assert [name for _, name in whole] == inventory
    for shard_total in shard_counts:
        group = "%s %s-way" % (suite, shard_total)
        shards = []
        def selected(index=0, **overrides):
            values = {"TEST_RUN_SUITE": suite, prefix + "_SHARD_TOTAL": str(shard_total),
                      prefix + "_SHARD_INDEX": str(index)}
            values.update(overrides)
            return values
        for index in range(shard_total):
            rows = run_case("%s shard %s preserves order, deadlines and nested isolation" % (group, index),
                           selected(index), nested=inventory[index])
            assert rows == whole[index::shard_total]
            shards.append(rows)
        assert Counter(tuple(row) for shard in shards for row in shard) == Counter(tuple(row) for row in whole)

        for label, values in (
            ("missing total", {prefix + "_SHARD_INDEX": "0"}),
            ("missing index", {prefix + "_SHARD_TOTAL": str(shard_total)}),
            ("empty index", {prefix + "_SHARD_TOTAL": str(shard_total), prefix + "_SHARD_INDEX": ""}),
            ("zero total", {prefix + "_SHARD_TOTAL": "0", prefix + "_SHARD_INDEX": "0"}),
            ("nondecimal total", {prefix + "_SHARD_TOTAL": "two", prefix + "_SHARD_INDEX": "0"}),
            ("leading zero index", {prefix + "_SHARD_TOTAL": str(shard_total), prefix + "_SHARD_INDEX": "00"}),
            ("negative index", {prefix + "_SHARD_TOTAL": str(shard_total), prefix + "_SHARD_INDEX": "-1"}),
            ("out of range", {prefix + "_SHARD_TOTAL": str(shard_total), prefix + "_SHARD_INDEX": str(shard_total)}),
            ("oversized integer", {prefix + "_SHARD_TOTAL": "9999999999999999999999", prefix + "_SHARD_INDEX": "0"}),
            ("empty shard", {prefix + "_SHARD_TOTAL": "999999999", prefix + "_SHARD_INDEX": "999999998"}),
        ):
            run_case(group + " " + label, dict(values, TEST_RUN_SUITE=suite), expected=2, invalid=True)
        for other in ("all", "domain-config" if suite == "fast" else "fast"):
            run_case(group + " selectors reject suite " + other,
                     selected(TEST_RUN_SUITE=other), expected=2, invalid=True)
        run_case(group + " integration selectors remain separate",
                 selected(TEST_SHARD_TOTAL="4", TEST_SHARD_INDEX="0"), expected=2, invalid=True)

        for index in range(shard_total):
            label = "%s shard %s" % (group, index)
            # Three selected scripts prove continuation after the first one
            # fails, while cancellation must never start the other two.
            for behavior, variable in (("failed script retains later coverage", "FIXTURE_FAIL_LABEL"),
                                        ("timeout retains later coverage", "FIXTURE_TIMEOUT_LABEL")):
                rows = run_case(label + " " + behavior, selected(index, **{variable: inventory[index]}),
                                expected=1, small=3 * shard_total)
                assert rows == shards[index][:3]
            run_case(label + " cancellation reaps child and restores state",
                     selected(index, FIXTURE_CANCEL_LABEL=inventory[index]), expected=143,
                     cancel=True, small=3 * shard_total)
run_case("fast and domain selectors cannot be combined", {
    "TEST_FAST_SHARD_TOTAL": "2", "TEST_FAST_SHARD_INDEX": "0",
    "TEST_DOMAIN_SHARD_TOTAL": "4", "TEST_DOMAIN_SHARD_INDEX": "0"}, expected=2, invalid=True)
# The pre-existing required fast checks must also gate the separately scheduled
# domain suite. Exercise their actual shell gates for every possible job result.
ci = (root / ".github/workflows/ci.yml").read_text()
public_layout = ci.startswith("# Public snapshot: GitHub-hosted CI only.\n")
docs_ci = (root / ".github/workflows/docs-check.yml").read_text()
assert public_layout == ("--public-export" in docs_ci), "CI and documentation layouts disagree"
if public_layout:
    for forbidden in ("self-hosted", "USE_SELF_HOSTED_", "dockistrate-private"):
        assert forbidden not in ci, "Public CI retained private runner selection"
    hosted_jobs = re.findall(r"(?ms)^  ([a-z][a-z-]*):\n(.*?)(?=^  [a-z][a-z-]*:\n|\Z)",
                             ci.split("\njobs:\n", 1)[1])
    assert hosted_jobs
    for name, body in hosted_jobs:
        expected_runner = "ubuntu-latest" if name == "persisted-render" else "${{ matrix.os }}"
        assert re.search(r"(?m)^    runs-on: (.+)$", body).group(1) == expected_runner, name
        operating_systems = re.findall(r"(?m)^          - ((?:ubuntu|macos)-[^\n]+)$", body)
        if name != "persisted-render":
            assert operating_systems and set(operating_systems) <= {"ubuntu-latest", "macos-latest"}, name
def job(text, name):
    return re.search(r"(?ms)^  " + re.escape(name) + r":\n(.*?)(?=^  [a-z][a-z-]*:|\Z)", text).group(1)
persisted_job = job(ci, "persisted-render")
expected_persisted_seconds = 1800 if public_layout else 600
expected_persisted_minutes = 35 if public_layout else 15
assert re.search(r"(?m)^  TEST_TIMEOUT_PERSISTED_RENDER_SECONDS: (\d+)$", ci).group(1) == str(expected_persisted_seconds)
assert re.search(r"(?m)^    timeout-minutes: (\d+)$", persisted_job).group(1) == str(expected_persisted_minutes)
assert "TEST_RUN_SUITE=persisted-render exec /bin/bash ./tests/run.sh" in persisted_job
for platform in ("linux", "macos"):
    for suite in ("integration-cli", "integration-feature-configs"):
        integration_job = job(ci, suite + "-" + platform)
        expected_seconds, expected_minutes = (1800, 35) if suite == "integration-cli" else (2400, 45)
        if public_layout and suite == "integration-feature-configs":
            expected_seconds, expected_minutes = 3600, 65
        assert re.search(r"(?m)^      TEST_TIMEOUT_INTEGRATION_SECONDS: (\d+)$", integration_job).group(1) == str(expected_seconds)
        assert re.search(r"(?m)^    timeout-minutes: (\d+)$", integration_job).group(1) == str(expected_minutes)
for platform in ("linux", "macos"):
    domain_job = job(ci, "domain-config-tests-" + platform)
    expected_shards = 4 if platform == "macos" else 2
    expected_minutes = 60 if public_layout else (35 if platform == "macos" else 25)
    assert "TEST_RUN_SUITE=domain-config exec /bin/bash ./tests/run.sh" in domain_job
    assert re.search(r"(?m)^      TEST_DOMAIN_SHARD_TOTAL: (\d+)$", domain_job).group(1) == str(expected_shards)
    assert "TEST_DOMAIN_SHARD_INDEX: ${{ matrix.domain_shard_index }}" in domain_job
    indices = re.search(r"(?m)^        domain_shard_index: \[([\d, ]+)\]$", domain_job)
    if indices is None:
        indices = re.search(r"(?m)^        domain_shard_index:\n((?:          - \d+\n)+)", domain_job)
    assert indices and [int(value) for value in re.findall(r"\d+", indices.group(1))] == list(range(expected_shards))
    assert re.search(r"(?m)^    timeout-minutes: (\d+)$", domain_job).group(1) == str(expected_minutes)
    assert "fail-fast: false" in domain_job
    fast_job = job(ci, "syntax-and-fast-tests-" + platform)
    expected_fast_minutes = 60 if public_layout else 25
    assert re.search(r"(?m)^    timeout-minutes: (\d+)$", fast_job).group(1) == str(expected_fast_minutes)
    assert "needs: domain-config-tests-" + platform in fast_job
    assert re.search(r"\$\{\{\s*always\(\)\s*&&\s*!cancelled\(\)(?:\s*&&|\s*}})", fast_job), \
        "Fast checks must run after domain failures but stop on workflow cancellation"
    gate = fast_job.split("      - name: Require domain configuration suite success\n", 1)[1]
    assert "if: always() && !cancelled()" in gate
    assert "${{ needs['domain-config-tests-" + platform + "'].result }}" in gate
    command = "\n".join(line[10:] for line in gate.split("        run: |\n", 1)[1].splitlines()
                        if line.startswith("          "))
    for result in ("success", "failure", "cancelled", "skipped", ""):
        process = subprocess.run([bash, "-e", "-c", command],
                                 env=dict(base_env, DOMAIN_SUITE_RESULT=result), capture_output=True)
        assert (process.returncode == 0) == (result == "success"), (platform, result)
    checks += 1
    print("[fast-runner-shards] PASS " + platform + " existing CI check gates domain results")
print("Script suite sharding: %s scheduling checks passed." % checks)
PY
