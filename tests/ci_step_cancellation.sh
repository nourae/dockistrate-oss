#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Signal only the enclosing CI step, exactly as runner cancellation does. Each
# fixture has its own session and state tree; cleanup never signals other tests.
exec python3 - "$ROOT_DIR" "$BASH" <<'PY'
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
bash = sys.argv[2]
workflow = (root / ".github/workflows/ci.yml").read_text().splitlines()
active_process = None
cancel_status = 0


def cancel_regression(received_signal, _frame):
    global cancel_status
    cancel_status = 128 + received_signal
    if active_process is not None and active_process.poll() is None:
        try:
            active_process.terminate()
        except ProcessLookupError:
            pass


signal.signal(signal.SIGTERM, cancel_regression)
signal.signal(signal.SIGINT, cancel_regression)


def step_command(name):
    start = workflow.index("      - name: " + name)
    for index in range(start + 1, len(workflow)):
        line = workflow[index]
        if line.startswith("        run: "):
            command = line[len("        run: "):]
            if command == "|":
                lines = []
                for following in workflow[index + 1:]:
                    if not following.startswith("          "):
                        break
                    lines.append(following[10:])
                command = "\n".join(lines)
            return command.replace("/bin/bash", shlex.quote(bash)) + "\n"
        if line.startswith("      - name:"):
            break
    raise AssertionError("Missing workflow command: " + name)


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


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def failure_snapshot(process, tree):
    # Capture survivors before finally terminates this isolated session. Keep
    # diagnostics off the successful path so they do not change signal timing.
    lines = ["Cancellation failure snapshot:",
             "outer pid=%s status=%s" % (process.pid, process.poll())]
    try:
        marker = tree / "pids"
        recorded = marker.read_text().strip() if marker.is_file() else "missing"
        lines.append("fixture/child readiness PIDs: " + recorded)
        lines.append("fixture cleanup done: " + str((tree / "done").is_file()))
        lines.append("state entries: " + repr(sorted(path.name for path in
                                                    (tree / "state").iterdir())))
        lines.append("session PID PPID PGID STATE COMMAND:")
        output = subprocess.check_output(
            ["ps", "-e", "-o", "pid=", "-o", "ppid=", "-o", "pgid=",
             "-o", "stat=", "-o", "comm="], text=True)
        members = []
        for row in output.splitlines():
            pid = int(row.split(None, 1)[0])
            try:
                if os.getsid(pid) == process.pid:
                    members.append(row.strip())
            except ProcessLookupError:
                pass
        lines.extend(members or ["(no remaining session members)"])
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        lines.append("snapshot unavailable: " + str(error))
    return "\n".join(lines)


fixture = r'''#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${FIXTURE_EXIT_STATUS:-}" != "" ]; then
  exit "$FIXTURE_EXIT_STATUS"
fi
source ./tests/lib/state_sandbox.sh
dockistrate_test_state_sandbox "$PWD"
child_pid=""
function finish_fixture() {
  trap '' INT TERM
  wait "$child_pid" 2>/dev/null || true
  # This final write must happen before the enclosing runner restores state.
  sleep 0.2
  printf 'late write\n' >state/late-write.txt
  dockistrate_test_state_sandbox_restore
  printf 'finished\n' >"$FIXTURE_DONE_FILE"
}
trap finish_fixture EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
printf 'test state\n' >state/test-write.txt
sleep 60 &
child_pid=$!
printf '%s %s\n' "$$" "$child_pid" >"${FIXTURE_PID_FILE}.ready"
mv "${FIXTURE_PID_FILE}.ready" "$FIXTURE_PID_FILE"
wait "$child_pid"
'''

cases = [
    ("Run fast test suite", "tests/function_reference_paths_exist.sh"),
    ("Run persisted render validation", "tests/persisted_render_validation.sh"),
    ("Run CLI integration suite", "tests/integration/test_cli.sh"),
    ("Run feature-config integration shard", "tests/integration/test_feature_configs.sh"),
    ("Run domain configuration suite", "tests/shared_csv_records.sh"),
]


def run_case(name, target, cancel_signal=None, status=None, interrupt_cleanup_wait=False):
    global active_process
    if cancel_status:
        sys.exit(cancel_status)
    label = name + ": " + (cancel_signal.name if cancel_signal else "exit " + str(status))
    if interrupt_cleanup_wait:
        label += " with interrupted cleanup wait"
    with tempfile.TemporaryDirectory(prefix="dockistrate-ci-cancel-") as temporary:
        tree = Path(temporary)
        for source in ("tests/run.sh", "tests/lib/run_with_timeout.sh", "tests/lib/state_sandbox.sh"):
            destination = tree / source
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / source, destination)
        (tree / "dockistrate.sh").write_text("#!/usr/bin/env bash\nexit 0\n")
        (tree / "dockistrate.sh").chmod(0o755)
        (tree / target).parent.mkdir(parents=True, exist_ok=True)
        (tree / target).write_text(fixture)
        (tree / target).chmod(0o755)
        (tree / "state").mkdir()
        (tree / "state/original.txt").write_text("original state\n")
        (tree / "step.sh").write_text(step_command(name))
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("TEST_", "DOCKISTRATE_TEST_STATE_SANDBOX"))}
        env.update(TEST_TIMEOUT_SECONDS="30", TEST_TIMEOUT_PERSISTED_RENDER_SECONDS="30",
                   TEST_TIMEOUT_INTEGRATION_SECONDS="30", TEST_TIMEOUT_GRACE_SECONDS="1",
                   TEST_SHARD_INDEX="0", TEST_SHARD_TOTAL="4",
                   FIXTURE_PID_FILE=str(tree / "pids"), FIXTURE_DONE_FILE=str(tree / "done"))
        if name == "Run domain configuration suite":
            env.pop("TEST_SHARD_INDEX")
            env.pop("TEST_SHARD_TOTAL")
            env.update(TEST_DOMAIN_SHARD_INDEX="0", TEST_DOMAIN_SHARD_TOTAL="2")
        env.pop("FIXTURE_EXIT_STATUS", None)
        if status is not None:
            env["FIXTURE_EXIT_STATUS"] = str(status)
        if interrupt_cleanup_wait:
            # Bash can retain a signal received at the end of an interrupted
            # wait and return it from the next wait without reaping its child.
            # Inject several results during each canceled layer's cleanup;
            # a fixed number of retries can restore state while writers live.
            wait_env = tree / "interrupt-cleanup-wait.sh"
            wait_env.write_text(r'''# shellcheck shell=bash
function wait() {
  if [ "${cancel_status:-0}" -ne 0 ] && [ "${cleanup_wait_interrupted:-0}" -lt 3 ]; then
    cleanup_wait_interrupted=$((${cleanup_wait_interrupted:-0} + 1))
    printf '%s\n' "$$" >>"$FIXTURE_WAIT_INTERRUPTED_FILE"
    return "$cancel_status"
  fi
  builtin wait "$@"
}
''')
            env.update(BASH_ENV=str(wait_env), FIXTURE_WAIT_INTERRUPTED_FILE=str(tree / "interrupted"))
        with (tree / "step.log").open("w") as log:
            process = subprocess.Popen([bash, "-e", str(tree / "step.sh")], cwd=tree,
                                       env=env, stdout=log, stderr=log, start_new_session=True)
            active_process = process
            try:
                if cancel_status:
                    sys.exit(cancel_status)
                if cancel_signal:
                    deadline = time.monotonic() + 10
                    while not (tree / "pids").exists():
                        if cancel_status:
                            sys.exit(cancel_status)
                        assert process.poll() is None, "Step exited before fixture became ready"
                        assert time.monotonic() < deadline, "Fixture did not become ready"
                        time.sleep(0.05)
                    pids = [int(value) for value in (tree / "pids").read_text().split()]
                    assert len(pids) == 2, "Incomplete fixture readiness marker"
                    os.kill(process.pid, cancel_signal)
                    expected = 128 + cancel_signal
                else:
                    expected = (0 if status == 0 else 1) if "persisted" in name else status
                result = process.wait(timeout=10)
                if cancel_status:
                    sys.exit(cancel_status)
                assert result == expected, "Expected status %s, got %s" % (expected, result)
                if cancel_signal:
                    assert (tree / "done").is_file(), "Fixture cleanup did not finish"
                    assert not any(alive(pid) for pid in pids), "Fixture or child survived cancellation"
                if interrupt_cleanup_wait:
                    interrupted = (tree / "interrupted").read_text().splitlines()
                    expected_layers = 2 if name in ("Run fast test suite", "Run domain configuration suite") else 1
                    assert len(set(interrupted)) == expected_layers, \
                        "Cleanup wait interruption did not reach every canceled layer"
                assert not session_members(process.pid), "A descendant survived the CI step"
                assert (tree / "state/original.txt").read_text() == "original state\n"
                assert sorted(path.name for path in (tree / "state").iterdir()) == ["original.txt"], \
                    "Canceled fixture wrote into restored state"
                assert not list((tree / "tmp").glob("tests-state-*")), "Sandbox cleanup is incomplete"
            except (AssertionError, subprocess.TimeoutExpired) as error:
                raise AssertionError(label + ": " + str(error) + "\n" +
                                     failure_snapshot(process, tree) + "\n" +
                                     (tree / "step.log").read_text()) from error
            finally:
                # Only this fixture's newly created session is eligible for cleanup.
                # Re-check membership before every signal, including failure paths.
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    for pid in session_members(process.pid):
                        try:
                            if os.getsid(pid) == process.pid:
                                os.kill(pid, sig)
                        except ProcessLookupError:
                            pass
                    if sig == signal.SIGTERM:
                        time.sleep(0.3)
                process.wait(timeout=5)
                active_process = None
        print("[tests] " + label + ": PASS")


for name, target in cases:
    for cancel_signal in (signal.SIGTERM, signal.SIGINT):
        run_case(name, target, cancel_signal=cancel_signal)

# Both the enclosing suite runner and the direct helper must wait through a
# stale signal status before state restoration and final process completion.
for name, target in (cases[0], cases[2], cases[4]):
    for cancel_signal in (signal.SIGTERM, signal.SIGINT):
        run_case(name, target, cancel_signal=cancel_signal, interrupt_cleanup_wait=True)

# The suite runner aggregates a failed test as status 1; a direct integration
# step preserves the command status. Both paths must retain normal completion.
for name, target in (cases[1], cases[2]):
    for status in (0, 7):
        run_case(name, target, status=status)
if cancel_status:
    sys.exit(cancel_status)
print("[tests] ci_step_cancellation.sh: PASS")
PY
