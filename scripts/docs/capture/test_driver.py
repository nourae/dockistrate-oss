"""Read-only PTY protocol checks using the repository's actual Bash chooser.

No Docker, runtime initialization, graphical packages, or screenshot claims are
involved. These checks catch capture-driver mistakes before a hosted live run.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

from .ui import UI
from .runtime import CaptureContext
from .terminal import _read_display_number
from .matrix import select_matrix


ROOT = Path(__file__).resolve().parents[3]
SOURCES = """
set -Eeuo pipefail
source lib/utils/validators.sh
source lib/cli/common.sh
source lib/cli/render_interactive.sh
source lib/cli/choose_option.sh
"""


class CaptureSelectionTest(unittest.TestCase):
    def test_selection_creates_only_the_requested_fresh_vms(self):
        self.assertEqual(len(select_matrix()["include"]), 22)
        self.assertEqual(select_matrix("security", "certificates"), {
            "include": [{"scenario": "security", "group": "certificates"}]})
        self.assertEqual(select_matrix("core", "baseline"), {
            "include": [{"scenario": "core", "group": "all"}]})
        self.assertEqual(len(select_matrix("operations")["include"]), 7)
        with self.assertRaisesRegex(ValueError, "No capture group"):
            select_matrix("core", "certificates")
        with self.assertRaisesRegex(ValueError, "Unknown capture scenario"):
            select_matrix("typo")


class DisplayAnnouncementTest(unittest.TestCase):
    def test_display_pipe_remains_open_until_the_separate_newline_write(self):
        read_fd, write_fd = os.pipe()
        producer = subprocess.Popen(
            [sys.executable, "-c",
             "import os,sys,time; fd=int(sys.argv[1]); "
             "os.write(fd,b'17'); time.sleep(0.1); os.write(fd,b'\\n')",
             str(write_fd)], pass_fds=(write_fd,), stderr=subprocess.PIPE,
        )
        os.close(write_fd)
        try:
            self.assertEqual(_read_display_number(read_fd), "17")
        finally:
            os.close(read_fd)
        _, error = producer.communicate(timeout=5)
        self.assertEqual(producer.returncode, 0, error.decode())

    def test_incomplete_announcement_is_not_accepted_as_a_display(self):
        read_fd, write_fd = os.pipe()
        os.write(write_fd, b"17")
        os.close(write_fd)
        try:
            with self.assertRaisesRegex(RuntimeError, "before the newline"):
                _read_display_number(read_fd)
        finally:
            os.close(read_fd)


class DriverProtocolTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="dockistrate-driver-check-")
        self.addCleanup(self.directory.cleanup)
        self.frames = []
        self.live_bytes = bytearray()
        self.context = SimpleNamespace(
            tool=ROOT, evidence=Path(self.directory.name), environment=dict(os.environ),
            source_commit="read-only-protocol-check", slug=lambda value: value,
            display=SimpleNamespace(columns=90, rows=48, reset=lambda: None,
                                    write=self.live_bytes.extend),
            capture=lambda ui, title, text, kind, **details: self.frames.append(
                dict(title=title, text=text, kind=kind, **details)),
            command_alias=lambda command: subprocess.check_output(
                ["bash", "-c", 'source lib/cli/command_alias.sh; command_alias "$1"', "check", command],
                cwd=ROOT, text=True).strip(),
        )
        self.context.capture_pages = self.context.capture

    def session(self, name, script):
        return UI(self.context, name, argv=["bash", "--noprofile", "--norc", "-c", SOURCES + script])

    def test_arrow_keys_capture_the_selected_real_menu_row(self):
        with self.session("arrows", """
choose_option picked 'Choose a protocol' HTTP HTTPS TCP
printf '\nchosen=%s\n' "$picked"
""") as ui:
            ui.menu(r"^HTTPS$", prompt="Choose a protocol")
            ui.finish_command(require=["chosen=1"])
        self.assertIn("> 2) HTTPS", self.frames[0]["text"])
        self.assertIn("↑↓ move", self.frames[0]["text"])
        self.assertEqual(self.live_bytes, (self.context.evidence / "arrows.pty.log").read_bytes())

    def test_readline_prefill_is_replaced_by_real_edit_keystrokes(self):
        with self.session("prefill", """
read -e -i previous-value -p 'Enter name: ' answer
printf '\nanswer=%s\n' "$answer"
""") as ui:
            ui.text(r"Enter name: ", "new")
            ui.finish_command(require=[r"answer=new(?:\n|$)"])
        self.assertIn("Enter name: new", self.frames[0]["text"])
        self.assertNotIn("previous-value", self.frames[0]["text"])

    def test_unnamed_review_argument_fails_before_execution(self):
        with self.session("unnamed-review", """
choose_option picked $'Review command\nArguments:\n  Argument 1:' Run Cancel
printf '\nexecuted\n'
""") as ui:
            with self.assertRaisesRegex(AssertionError, "review contains unnamed arguments"):
                ui.menu(r"^Run$", prompt="Review command")
            self.assertIsNone(ui.process.poll())
        events = [json.loads(line) for line in
                  (self.context.evidence / "unnamed-review.events.jsonl").read_text().splitlines()]
        self.assertFalse(any(event["kind"] == "keystrokes" for event in events))

    def test_choice_matches_value_with_current_setting_annotation(self):
        with self.session("current", """
choose_option picked 'Current protocol' 'HTTP (current)' HTTPS
printf '\nchosen=%s\n' "$picked"
""") as ui:
            ui.menu(r"^HTTP$", enter=True)
            ui.finish_command(require=["chosen=0"])
        self.assertEqual(self.frames[0]["selected"], "HTTP (current)")

    def test_hidden_input_is_not_in_raw_capture_or_events(self):
        with self.session("hidden", """
read -rs -p 'Demo password: ' answer
test "$answer" = disposable-demo
printf '\naccepted\n'
""") as ui:
            ui.text(r"Demo password: ", "disposable-demo", secret=True)
            ui.finish_command(require=["accepted"])
        self.assertNotIn(b"disposable-demo", self.live_bytes)
        events = (self.context.evidence / "hidden.events.jsonl").read_text()
        # The session command intentionally contains the comparison literal;
        # input events themselves must never retain the hidden input value.
        inputs = [event for event in map(json.loads, events.splitlines())
                  if event["kind"] in ("keystrokes", "input")]
        self.assertTrue(all(event.get("value") != "disposable-demo" for event in inputs))

    def test_global_search_selects_the_exact_real_command(self):
        with self.session("search", """
source lib/cli/command_alias.sh
source lib/cli/command_descriptions.sh
source lib/cli/command_description.sh
source lib/cli/format_command_display.sh
source lib/cli/interactive_picker_menu_data.sh
source lib/cli/choose_command_with_filter.sh
choose_option home 'What do you want to do' 'Search all commands' Quit
filter=''
choose_global_command_with_filter picked filter 'Search commands'
printf '\ncommand=%s\n' "$picked"
""") as ui:
            ui.command("add-backend")
            ui.finish_command(require=[r"command=add-backend(?:\n|$)"])
        self.assertEqual(self.frames[-2]["selected"].split(" :: ")[1].split(" — ")[0], "Add Backend")

    def test_terminal_hyperlink_keeps_its_visible_location_url(self):
        with self.session("hyperlink", r"""
printf 'Location: \033]8;;https://example.com/\033\\https://example.com/\033]8;;\033\\\n'
""") as ui:
            ui.finish_command(require=[r"Location: https://example\.com/"])
        self.assertIn(b"\x1b]8;;", self.live_bytes)
        self.assertEqual(self.frames[-1]["text"].strip(), "Location: https://example.com/")

    def test_repeated_journeys_keep_distinct_original_pty_logs(self):
        names = []
        for value in ("before-change", "after-change"):
            with self.session("repeated", "printf '%s\\n' " + value) as ui:
                ui.finish_command(require=[value])
                names.append(ui.journey)
                self.assertEqual(ui.journey_family, "repeated")
        self.assertNotEqual(*names)
        for name, value in zip(names, ("before-change", "after-change")):
            raw = (self.context.evidence / (name + ".pty.log")).read_bytes()
            self.assertEqual(raw.strip().decode(), value)

    def test_non_pty_certificate_bytes_never_enter_retained_evidence(self):
        # Deliberately invalid material exercises the retention boundary without
        # introducing a real certificate or key into the test source/artifacts.
        material = "-----BEGIN CERTIFICATE-----\nnot-a-certificate\n-----END CERTIFICATE-----\n"
        context = CaptureContext(ROOT, Path(self.directory.name) / "retention", "driver-check")
        try:
            result = context.run([sys.executable, "-c", "import sys; sys.stdout.write(sys.stdin.read())"],
                                 label="sensitive-output", input=material)
            self.assertEqual(result, material)
            records = list(map(json.loads, (context.evidence / "commands.jsonl").read_text().splitlines()))
            self.assertFalse(records[-1]["output_retained"])
            self.assertFalse(records[-1]["input"]["retained"])
            self.assertNotIn(material, json.dumps(records))
            log = context.output / records[-1]["log"]
            self.assertNotIn("BEGIN CERTIFICATE", log.read_text())
            self.assertIn("SHA-256:", log.read_text())
            with self.assertRaises(AssertionError) as failure:
                context.run([sys.executable, "-c", "import sys; print(sys.stdin.read()); sys.exit(7)"],
                            label="sensitive-failure", input=material, retain_output=False)
            self.assertNotIn("BEGIN CERTIFICATE", str(failure.exception))
        finally:
            context.close("test-only")


if __name__ == "__main__":
    unittest.main()
