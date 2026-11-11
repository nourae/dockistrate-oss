"""Drive real Dockistrate menus, retaining original bytes and visible frames."""

import fcntl
import codecs
import json
import os
import pty
import re
import select
import signal
import struct
import subprocess
import termios
import time

ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
MENU_END = re.compile(r"↑↓ move  Enter select[^\r\n]*\? help")
SEARCH_END = re.compile(r"Enter finish search[^\r\n]*\? help")
ROW = re.compile(r"^([> ])\s*(\d+)\) (.*)$", re.M)


def visible_text(raw):
    """Extract the latest redraw, honoring readline's inline edits.

    This is a plain-text excerpt, not the screenshot renderer. The PNG always
    comes from xterm; the original unmodified bytes remain in the PTY log.
    """
    raw = raw.split("\x1b[H")[-1]
    lines, line, column = [], [], 0
    for token in re.findall(ANSI.pattern + r"|[^\x1b]", raw):
        if token.startswith("\x1b"):
            if re.fullmatch(r"\x1b\[(?:0)?K", token):
                del line[column:]
            elif token == "\x1b[2K":
                line = []
            elif re.fullmatch(r"\x1b\[\d*G", token):
                column = max(0, int(token[2:-1] or "1") - 1)
            elif re.fullmatch(r"\x1b\[\d*[CD]", token):
                distance = int(token[2:-1] or "1")
                column = max(0, column + (distance if token[-1] == "C" else -distance))
            continue
        if token == "\n":
            lines.append("".join(line).rstrip())
            line, column = [], 0
        elif token == "\r":
            column = 0
        elif token == "\b":
            column = max(0, column - 1)
        elif token == "\t":
            column += 8 - column % 8
        elif token >= " ":
            if column >= len(line):
                line.extend(" " for _ in range(column - len(line) + 1))
            line[column] = token
            column += 1
    lines.append("".join(line).rstrip())
    return "\n".join(lines)


class UI:
    def __init__(self, context, journey, command=None, argv=None):
        self.context = context
        self.journey_family = context.slug(journey)
        if not hasattr(context, "journey_counts"):
            context.journey_counts = {}
        self.session_index = context.journey_counts.get(self.journey_family, 0) + 1
        context.journey_counts[self.journey_family] = self.session_index
        # A double hyphen cannot occur in a slugged family. This suffix keeps
        # repeated observations distinct without colliding with another family.
        self.journey = self.journey_family
        if self.session_index > 1:
            self.journey += f"--session-{self.session_index:03d}"
        self.command_name = command
        self.buffer = ""
        self.raw_offset = 0
        self.step = 0
        self.closed = False
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.raw = (context.evidence / (self.journey + ".pty.log")).open("wb")
        self.events = (context.evidence / (self.journey + ".events.jsonl")).open("w")
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", context.display.rows, context.display.columns, 0, 0))
        self.argv = argv or [str(context.tool / "dockistrate.sh"), "-i"]
        environment = dict(context.environment, TERM="xterm-256color", DOCKISTRATE_NO_CLEAR="false",
                           COLUMNS=str(context.display.columns), LINES=str(context.display.rows))
        context.display.reset()
        self.process = subprocess.Popen(
            self.argv, cwd=context.tool, env=environment, stdin=slave, stdout=slave,
            stderr=slave, start_new_session=True,
        )
        os.close(slave)
        self.record("session", argv=self.argv, source_commit=context.source_commit)
        print(f"[capture] {self.journey}", flush=True)

    def __enter__(self):
        return self

    def __exit__(self, error_type, error, traceback):
        try:
            if error:
                self.record("failure", error=str(error), unread_output=self.buffer[-6000:])
                try:
                    self.context.capture(self, "failure", visible_text(self.buffer), "failure")
                except Exception as capture_error:
                    self.record("capture-failure", error=str(capture_error))
        finally:
            self.close()

    def record(self, kind, **fields):
        self.events.write(json.dumps({"kind": kind, "command": self.command_name,
                                     "journey": self.journey, "journey_family": self.journey_family,
                                     "session_index": self.session_index,
                                     "pty_byte_offset": self.raw_offset, **fields}) + "\n")
        self.events.flush()

    def _read(self, wait=0.2):
        if not select.select([self.master], [], [], wait)[0]:
            return False
        try:
            chunk = os.read(self.master, 65536)
        except OSError:
            chunk = b""
        if not chunk:
            return False
        self.raw.write(chunk)
        self.raw.flush()
        self.raw_offset += len(chunk)
        self.context.display.write(chunk)
        self.buffer += self.decoder.decode(chunk)
        return True

    def expect(self, pattern, timeout=90):
        regex = re.compile(pattern) if isinstance(pattern, str) else pattern
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            match = regex.search(self.buffer)
            if match:
                output, self.buffer = self.buffer[:match.end()], self.buffer[match.end():]
                return output
            if not self._read() and self.process.poll() is not None:
                raise AssertionError(f"{self.journey}: exited {self.process.returncode} waiting for "
                                     f"{regex.pattern!r}: {self.buffer[-6000:]}")
        raise TimeoutError(f"{self.journey}: waiting for {regex.pattern!r}: {self.buffer[-6000:]}")

    def send(self, value, *, secret=False):
        self.record("keystrokes", value="[redacted]" if secret else value)
        os.write(self.master, value.encode())

    def snapshot(self, title, *, kind="observed", wait=0.5):
        """Capture a live stream without pretending it has completed."""
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            self._read(0.05)
        return self.context.capture(self, title, visible_text(self.buffer), kind)

    def menu(self, choice, *, prompt=None, require=(), enter=False, first_match=False, title=None):
        raw = self.expect(MENU_END)
        screen = visible_text(raw)
        if (re.search(r"^Review command\s*$", screen, re.M) and
                re.search(r"^\s+Argument [0-9]+:", screen, re.M)):
            raise AssertionError(f"{self.journey}: review contains unnamed arguments:\n{screen}")
        if prompt and not re.search(prompt, screen, re.I):
            raise AssertionError(f"{self.journey}: expected {prompt!r}:\n{screen}")
        for expected in require:
            if not re.search(expected, screen, re.I):
                raise AssertionError(f"{self.journey}: missing {expected!r}:\n{screen}")
        rows = ROW.findall(screen)
        matches = [(marker, int(number), label) for marker, number, label in rows
                   if re.search(choice, label, re.I) or
                   re.search(choice, re.sub(r" \(current\)$", "", label), re.I)]
        if len(matches) != 1 and not (first_match and matches):
            raise AssertionError(f"{self.journey}: expected one {choice!r}, got {matches!r}:\n{screen}")
        marker, number, label = matches[0]
        if enter and marker != ">":
            raise AssertionError(f"{self.journey}: expected {label!r} selected by default")
        selected = next(int(number) for marker, number, _ in rows if marker == ">")
        # Use real arrow navigation and photograph the actual highlighted choice.
        for _ in range(abs(number - selected)):
            self.send("\x1b[B" if number > selected else "\x1b[A")
            screen = visible_text(self.expect(MENU_END))
        if not any(marker == ">" and int(item) == number for marker, item, _ in ROW.findall(screen)):
            raise AssertionError("Arrow navigation did not select the intended row")
        inferred = re.search(r"Command: .*\(([a-z0-9-]+)\)", screen)
        if inferred:
            self.command_name = inferred.group(1)
        self.context.capture(self, title or label, screen, "menu", selected=label)
        self.record("menu", screen=screen, selected=label)
        self.send("\n")
        return screen

    def text(self, prompt, value, *, title=None, replace=True, secret=False):
        raw = self.expect(prompt)
        if replace:
            self.send("\x15")
        self.send(value, secret=secret)
        # read/readline echo is part of the application's PTY, not painted text.
        if value:
            deadline = time.monotonic() + 0.5
            while time.monotonic() < deadline:
                self._read(0.05)
        self.context.capture(self, title or "Enter value", visible_text(raw + self.buffer),
                             "input", value="[redacted]" if secret else value)
        self.record("input", prompt=visible_text(raw), value="[redacted]" if secret else value)
        self.send("\n")

    def finish_command(self, *, expected_exit=0, require=(), title="Verification result", timeout=180):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            read = self._read(0.1)
            if not read and self.process.poll() is not None:
                break
        else:
            raise TimeoutError(self.journey + ": verification command timed out")
        output = visible_text(self.buffer)
        self.buffer = ""
        status = self.process.wait(timeout=5)
        self.record("exit", exit_code=status)
        self.context.capture_pages(self, title, output, "verification", exit_code=status)
        if status != expected_exit:
            raise AssertionError(f"{self.journey}: exited {status}, expected {expected_exit}:\n{output}")
        for expected in require:
            if not re.search(expected, output, re.I):
                raise AssertionError(f"{self.journey}: result omitted {expected!r}:\n{output}")
        return output

    def start(self, home, command=None):
        self.menu(home, prompt="What do you want to do", title="Choose a task")
        if command is not None:
            self.menu(command, title="Choose a command")

    def command(self, command):
        self.command_name = command
        self.start(r"^Search all commands$")
        self.expect(MENU_END)
        self.send("/")
        self.expect(SEARCH_END)
        for character in command:
            self.send(character)
            self.expect(SEARCH_END)
        self.send("\n")
        alias = self.context.command_alias(command)
        return self.menu(r":: " + re.escape(alias) + r"(?: —|$)",
                         title="Find " + alias)

    def finish(self, require=(), *, title=None):
        # status/status-all own their refresh/continue prompt; the entry point
        # intentionally skips its usual completion pause for those commands.
        raw = self.expect(r"Press (?:R to refresh or )?Enter to continue\.\.\.", timeout=180)
        output = visible_text(raw)
        if "[Error]" in output or "[Fatal]" in output:
            raise AssertionError(f"{self.journey}: execution failed:\n{output}")
        for expected in require:
            if not re.search(expected, output, re.I):
                raise AssertionError(f"{self.journey}: result omitted {expected!r}:\n{output}")
        self.context.capture_pages(self, title or "Command result", output, "result")
        self.record("result", output=output)
        self.send("\n")
        self.quit()
        return output

    def quit(self):
        self.menu(r"^Quit$", prompt="What do you want to do", title="Return to Home")
        deadline = time.monotonic() + 20
        while self.process.poll() is None and time.monotonic() < deadline:
            self._read(0.1)
        status = self.process.wait(timeout=5)
        self.record("exit", exit_code=status)
        if status:
            raise AssertionError(f"{self.journey}: exited {status}")

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=10)
        os.close(self.master)
        self.raw.close()
        self.events.close()
