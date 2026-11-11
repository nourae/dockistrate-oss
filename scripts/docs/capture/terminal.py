"""Display the live application's PTY bytes in xterm and photograph that window."""

import os
from pathlib import Path
import re
import select
import signal
import subprocess
import time


def _read_display_number(read_fd, timeout=15):
    """Read Xvfb's complete reply before closing its announcement pipe.

    The number and terminating newline can arrive in separate writes. Closing
    after the first readable chunk makes Xvfb's remaining write fail with EPIPE.
    """
    deadline = time.monotonic() + timeout
    response = bytearray()
    while b"\n" not in response:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([read_fd], [], [], remaining)[0]:
            raise RuntimeError("Xvfb did not announce a complete display number")
        chunk = os.read(read_fd, 64)
        if not chunk:
            raise RuntimeError("Xvfb closed its announcement pipe before the newline")
        response.extend(chunk)
        if len(response) > 32:
            raise RuntimeError("Invalid Xvfb display response")
    if not re.fullmatch(rb"[0-9]+\n", response):
        raise RuntimeError("Invalid Xvfb display response")
    return response[:-1].decode("ascii")


class TerminalDisplay:
    columns = 90
    rows = 48

    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.processes = []
        self.writer = None
        self.window = None
        self.environment = dict(os.environ)
        self.log = (self.directory / "display.log").open("wb")
        try:
            read_fd, write_fd = os.pipe()
            xvfb = subprocess.Popen(
                ["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "1800x1500x24",
                 "-nolisten", "tcp", "-noreset"],
                pass_fds=(write_fd,), stdout=self.log, stderr=self.log,
                start_new_session=True,
            )
            self.processes.append(xvfb)
            os.close(write_fd)
            try:
                display = _read_display_number(read_fd)
            finally:
                os.close(read_fd)
            self.environment["DISPLAY"] = ":" + display
            fifo = self.directory / "terminal.fifo"
            os.mkfifo(fifo, 0o600)
            # Keep both ends open while xterm starts; no application text is invented.
            self.writer = os.open(fifo, os.O_RDWR)
            terminal = subprocess.Popen(
                ["xterm", "-T", "Dockistrate documentation capture", "-fa", "DejaVu Sans Mono",
                 "-fs", "13", "-geometry", f"{self.columns}x{self.rows}+0+0", "+sb", "-b", "14",
                 "-bg", "#111827", "-fg", "#e5e7eb", "+bc", "-sl", "10000", "-e", "sh", "-c",
                 'stty raw -echo; exec cat "$1"', "capture-reader", str(fifo)],
                env=self.environment, stdout=self.log, stderr=self.log, start_new_session=True,
            )
            self.processes.append(terminal)
            for _ in range(100):
                result = subprocess.run(
                    ["xwininfo", "-root", "-tree"], env=self.environment,
                    text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                )
                match = re.search(r'(0x[0-9a-f]+) "Dockistrate documentation capture"', result.stdout)
                if match:
                    self.window = match.group(1)
                    break
                if terminal.poll() is not None:
                    self.log.flush()
                    detail = (self.directory / "display.log").read_text(errors="replace")[-3000:]
                    raise RuntimeError("xterm exited before its window was available:\n" + detail)
                time.sleep(0.1)
            if self.window is None:
                raise RuntimeError("Could not locate the live xterm window")
        except BaseException:
            self.close()
            raise

    def write(self, data):
        remaining = memoryview(data)
        while remaining:
            count = os.write(self.writer, remaining)
            remaining = remaining[count:]

    def reset(self):
        # Clear only the display between independent application sessions.
        self.write(b"\x1b[0m\x1b[3J\x1b[2J\x1b[H")

    def scroll(self, direction):
        """Navigate the actual xterm scrollback using X11 keyboard events."""
        key = {"up": "shift+Prior", "down": "shift+Next"}[direction]
        subprocess.run(["xdotool", "windowfocus", "--sync", self.window], env=self.environment,
                       stdout=subprocess.DEVNULL, stderr=self.log, check=True, timeout=10)
        subprocess.run(["xdotool", "key", "--clearmodifiers", key], env=self.environment,
                       stdout=subprocess.DEVNULL, stderr=self.log, check=True, timeout=10)
        time.sleep(0.1)

    def screenshot(self, path):
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        # Let the X server paint bytes already written by the real PTY.
        time.sleep(0.2)
        subprocess.run(
            ["import", "-window", self.window, str(path)], env=self.environment,
            stdout=subprocess.DEVNULL, stderr=self.log, check=True, timeout=20,
        )
        # Crop only the uniform window background and restore a consistent
        # margin. Pixels containing the genuine terminal output are unchanged.
        subprocess.run(
            ["convert", str(path), "-shave", "2x2", "-trim", "+repage",
             "-bordercolor", "#111827", "-border", "14", str(path)],
            env=self.environment, stdout=subprocess.DEVNULL, stderr=self.log,
            check=True, timeout=20,
        )
        if path.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            raise RuntimeError("Screenshot did not produce a PNG")

    def close(self):
        if self.writer is not None:
            os.close(self.writer)
            self.writer = None
        for process in reversed(self.processes):
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
        self.processes = []
        if hasattr(self, "log") and not self.log.closed:
            self.log.close()
