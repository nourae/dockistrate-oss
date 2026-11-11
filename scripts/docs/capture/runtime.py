"""Disposable-environment context and inspectable capture/verification evidence."""

import csv
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

from .terminal import TerminalDisplay
from .ui import UI

PEM_HEADER = re.compile(r"-----BEGIN [A-Z0-9 ]+-----")


class CaptureContext:
    domain = "example.com"
    backend = "backend-example.com"
    network = "dockistrate-net"
    image = "nginx:alpine"

    def __init__(self, tool, output, scenario):
        self.tool = Path(tool).resolve()
        self.output = Path(output).resolve()
        self.scenario = self.slug(scenario)
        self.evidence = self.output / "evidence" / self.scenario
        self.evidence.mkdir(parents=True, exist_ok=True)
        self.environment = dict(os.environ, LC_ALL="C.UTF-8", LANG="C.UTF-8")
        self.environment.pop("SKIP_DOCKER_CHECKS", None)
        self.commands = (self.evidence / "commands.jsonl").open("w")
        self.command_index = 0
        self.frames = []
        self.checks = []
        self.source_commit = self.run(["git", "rev-parse", "HEAD"], label="source-commit").strip()
        self.display = None
        self.display_directory = None
        self.metadata = {
            "schema_version": 1, "scenario": self.scenario,
            "source_commit": self.source_commit,
            "started_at": datetime.now(timezone.utc).isoformat(),
            "capture_method": "live PTY bytes displayed by xterm; X11 window screenshot; uniform background trimmed with 14px padding",
            "terminal": {"columns": TerminalDisplay.columns, "rows": TerminalDisplay.rows,
                         "font": "DejaVu Sans Mono", "font_size": 13, "padding_pixels": 14},
            "github_run_id": os.environ.get("GITHUB_RUN_ID"),
            "github_run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT"),
        }

    @staticmethod
    def slug(value):
        value = re.sub(r"[^a-z0-9]+", "-", str(value).lower()).strip("-")
        if not value:
            raise ValueError("An artifact label must contain letters or digits")
        return value[:80]

    def preflight(self):
        # This developer harness deliberately has no route to an operator's daemon.
        if (os.environ.get("GITHUB_ACTIONS") != "true" or
                os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"):
            raise RuntimeError("Capture requires a disposable GitHub-hosted runner")
        if (self.tool / "state").exists():
            raise RuntimeError("Capture requires a fresh checkout without runtime state")
        for executable in ["docker", "curl", "openssl", "Xvfb", "xterm", "xwininfo", "import", "convert", "xdotool"]:
            if not shutil.which(executable):
                raise RuntimeError("Missing capture dependency: " + executable)
        if self.run(["docker", "ps", "-aq"], label="empty-daemon").strip():
            raise RuntimeError("Capture refuses a Docker daemon containing existing containers")
        # The runner user cannot bind privileged ports, although its Docker
        # daemon can. Elevate only this short-lived availability probe.
        port_probe = (
            "import socket\n"
            "for port, kind in [(80, socket.SOCK_STREAM), (443, socket.SOCK_STREAM), (443, socket.SOCK_DGRAM)]:\n"
            "    with socket.socket(socket.AF_INET, kind) as probe:\n"
            "        probe.bind(('0.0.0.0', port))\n"
            "print('TCP 80/443 and UDP 443 are available')\n"
        )
        self.run([*(["sudo", "-n"] if os.geteuid() else []), sys.executable, "-c", port_probe],
                 label="free-demo-listeners")
        self.metadata["versions"] = {
            "bash": self.run(["bash", "--version"], label="bash-version").splitlines()[0],
            "docker": self.run(["docker", "version", "--format", "{{.Server.Version}}"], label="docker-version").strip(),
            "kernel": self.run(["uname", "-srmo"], label="kernel-version").strip(),
            "curl": self.run(["curl", "--version"], label="curl-version").splitlines()[0],
        }
        self.display_directory = tempfile.TemporaryDirectory(prefix="dockistrate-docs-display-")
        self.display = TerminalDisplay(self.display_directory.name)
        # Image pulls are the unsupported fixture-provisioning operation; all
        # backend/proxy/network/config mutations below use Dockistrate itself.
        self.run(["docker", "pull", self.image], label="fixture-image", timeout=300)
        self.cli("fixture-backups", "set-auto-backups", "false")

    def run(self, argv, *, label="command", timeout=180, input=None, check=True,
            retain_output=True):
        self.command_index += 1
        stem = f"{self.command_index:03d}-{self.slug(label)}"
        started = time.monotonic()
        try:
            result = subprocess.run(
                [str(value) for value in argv], cwd=self.tool, env=self.environment,
                input=input, text=True, errors="replace", stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, timeout=timeout,
            )
            output, status = result.stdout, result.returncode
        except subprocess.TimeoutExpired as error:
            output = error.stdout or ""
            if isinstance(output, bytes):
                output = output.decode(errors="replace")
            status = 124
        log = self.evidence / (stem + ".log")
        output_bytes = output.encode()
        output_sha256 = hashlib.sha256(output_bytes).hexdigest()
        has_pem_output = bool(PEM_HEADER.search(output))
        retained = retain_output and not has_pem_output
        if retained:
            log.write_text(output)
        else:
            reason = "certificate/key material" if has_pem_output else "explicitly private verification output"
            log.write_text("Command output was kept in memory only: " + reason + ".\n" +
                           f"SHA-256: {output_sha256}\nBytes: {len(output_bytes)}\n")
        recorded_input = input
        if input is not None and PEM_HEADER.search(input):
            recorded_input = {"retained": False, "reason": "certificate/key material",
                              "sha256": hashlib.sha256(input.encode()).hexdigest(),
                              "bytes": len(input.encode())}
        self.commands.write(json.dumps({"argv": [str(value) for value in argv],
                                        "input": recorded_input, "exit_code": status,
                                        "output_retained": retained, "output_sha256": output_sha256,
                                        "output_bytes": len(output_bytes),
                                        "duration_seconds": round(time.monotonic() - started, 3),
                                        "log": str(log.relative_to(self.output))}) + "\n")
        self.commands.flush()
        if check and status:
            detail = output[-6000:] if retained else "Output withheld from artifacts; see command metadata."
            raise AssertionError(f"{label}: exited {status}:\n{detail}")
        return output

    def cli(self, label, *args, **options):
        return self.run([self.tool / "dockistrate.sh", *args], label=label, timeout=options.pop("timeout", 300), **options)

    def command_alias(self, command):
        return self.run(
            ["bash", "-c", 'source lib/cli/command_alias.sh; command_alias "$1"', "capture", command],
            label="command-alias",
        ).strip()

    def ui(self, journey, command=None):
        return UI(self, self.scenario + "-" + self.slug(journey), command)

    def terminal_command(self, journey, argv, *, expected_exit=0, require=(), title="Verification result", timeout=180):
        # The shell displays and executes these exact arguments inside a real PTY.
        # No saved output is replayed and no result text is composed by the driver.
        script = 'printf "\\033[2J\\033[H$ "; printf "%q " "$@"; printf "\\n"; "$@"'
        actual = ["bash", "--noprofile", "--norc", "-c", script, "verification", *map(str, argv)]
        with UI(self, self.scenario + "-" + self.slug(journey), argv=actual) as terminal:
            terminal.record("verification-command", argv=list(map(str, argv)))
            output = terminal.finish_command(expected_exit=expected_exit, require=require, title=title, timeout=timeout)
        self.proof(journey, argv=list(map(str, argv)), expected_exit=expected_exit)
        return output

    def capture(self, ui, title, text, kind, **fields):
        ui.step += 1
        relative = Path("docs/assets/interactive") / ui.journey / f"{ui.step:02d}-{self.slug(title)}.png"
        image = self.output / relative
        self.display.screenshot(image)
        transcript = image.with_suffix(".txt")
        transcript.write_text(text.rstrip() + "\n")
        frame = {"journey": ui.journey, "journey_family": ui.journey_family,
                 "session_index": ui.session_index, "step": ui.step, "title": title, "kind": kind,
                 "command": ui.command_name, "image": str(relative),
                 "transcript": str(transcript.relative_to(self.output)),
                 "image_sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
                 "transcript_sha256": hashlib.sha256(transcript.read_bytes()).hexdigest(),
                 "pty_log": str((self.evidence / (ui.journey + ".pty.log")).relative_to(self.output)),
                 "pty_byte_offset": ui.raw_offset, **fields}
        self.frames.append(frame)
        self.write_manifest("running")
        return frame

    def capture_pages(self, ui, title, text, kind, **fields):
        """Photograph long output via live xterm scrollback, never by replay.

        Every TXT remains the complete output excerpt. A frame records how far
        its viewport was moved from the current bottom of the real terminal.
        """
        current = self.capture(ui, title, text, kind, viewport="bottom", **fields)
        rendered_rows = sum(max(1, (len(line) + self.display.columns - 1) // self.display.columns)
                            for line in text.splitlines())
        if rendered_rows <= self.display.rows:
            return current
        # xterm's standard Shift+PageUp moves half a page; overlap preserves
        # context and ensures wrapped rows are not omitted between screenshots.
        half_page = max(1, self.display.rows // 2)
        page_count = (rendered_rows - self.display.rows + half_page - 1) // half_page
        previous_hash, steps = current["image_sha256"], 0
        try:
            for step in range(1, page_count + 1):
                self.display.scroll("up")
                steps += 1
                ui.record("display-navigation", key="Shift+PageUp", scrollback_steps=steps)
                frame = self.capture(ui, title + f" — earlier output {step}", text, kind,
                                     viewport="top" if step == page_count else "scrollback",
                                     scrollback_steps=steps, **fields)
                if frame["image_sha256"] == previous_hash:
                    break
                previous_hash = frame["image_sha256"]
        finally:
            for _ in range(steps):
                self.display.scroll("down")
            ui.record("display-navigation", key="Shift+PageDown", count=steps,
                      viewport="bottom")
        return current

    def request(self, label, expected=200, *, https=False, agent=None, header=None,
                domain=None, path="/", extra=()):
        domain = domain or self.domain
        port = 443 if https else 80
        headers = self.evidence / (self.slug(label) + ".headers")
        body = self.evidence / (self.slug(label) + ".body")
        argv = ["curl", "--noproxy", "*", "-sS", "--connect-timeout", "2", "--max-time", "10",
                "--resolve", f"{domain}:{port}:127.0.0.1", "-D", str(headers), "-o", str(body),
                "-w", "%{http_code}"]
        if https:
            argv.append("-k")
        if agent is not None:
            argv += ["-A", agent]
        argv += list(extra)
        argv += [f"{'https' if https else 'http'}://{domain}{path}"]
        # Retry connection startup only. A wrong HTTP decision fails immediately.
        for attempt in range(6):
            result = subprocess.run(argv, cwd=self.tool, env=self.environment,
                                    text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode != 7:
                break
            time.sleep(1)
        (self.evidence / (self.slug(label) + ".status")).write_text(result.stdout + "\n")
        (self.evidence / (self.slug(label) + ".stderr")).write_text(result.stderr)
        self.commands.write(json.dumps({"argv": argv, "exit_code": result.returncode,
                                        "http_status": result.stdout, "label": label}) + "\n")
        self.commands.flush()
        if result.returncode or result.stdout != str(expected):
            raise AssertionError(f"{label}: expected HTTP {expected}, got {result.stdout}/{result.returncode}: {result.stderr}")
        observed_headers = headers.read_text().lower()
        if header is True and "x-interactive-draft: activated" not in observed_headers:
            raise AssertionError(label + ": activated draft header missing")
        if header is False and "x-interactive-draft:" in observed_headers:
            raise AssertionError(label + ": unapplied draft became active")
        self.proof(label, "passed", http_status=int(result.stdout), headers=str(headers.relative_to(self.output)))
        return body.read_text(errors="replace")

    def proof(self, label, status="passed", **details):
        self.checks.append({"label": label, "status": status, **details})
        self.write_manifest("running")

    def ensure_backend(self, https=True):
        owner = self.tool / "state/domains" / self.domain
        if not (owner / "runtime/applied/backend.csv").is_file():
            self.cli("fixture-backend", "add-backend", self.domain, self.image, "80", "http")
            self.cli("fixture-public-demo", "set-backend-acl-policy", self.domain, "allow")
        if https:
            ports = list(csv.DictReader((owner / "runtime/applied/ports.csv").open()))
            if not any(row["listen_port"] == "443" for row in ports):
                self.cli("fixture-https", "add-port", self.domain, "443", "80", "https", "none", "no")
        self.cli("fixture-check", "check-config")
        return owner

    def check_config(self, label="check-config"):
        with self.ui(label, command="check-config") as ui:
            ui.start(r"^Diagnostics / troubleshoot$", r"^Check Config(?:\s|$)")
            return ui.finish(require=["successful"], title="Configuration test passed")

    def runtime_snapshot(self):
        return self.run(["docker", "inspect", "--format", "{{.Id}}|{{.State.Status}}|{{.State.StartedAt}}",
                         self.backend, "nginx-proxy"], label="runtime-identities") + self.run(
            ["docker", "top", "nginx-proxy", "-eo", "pid,comm,args"], label="runtime-processes")

    def write_manifest(self, status, error=None):
        document = {**self.metadata, "status": status, "frames": self.frames, "checks": self.checks}
        if error is not None:
            document["error"] = str(error)
        destination = self.output / "docs/assets/interactive" / (self.scenario + "-provenance.json")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(document, indent=2) + "\n")

    def close(self, status, error=None):
        try:
            if self.display is not None:
                self.display.close()
            if self.display_directory is not None:
                log = Path(self.display_directory.name) / "display.log"
                if log.exists():
                    shutil.copyfile(log, self.evidence / "display.log")
            self.metadata["finished_at"] = datetime.now(timezone.utc).isoformat()
            self.write_manifest(status, error)
        finally:
            if self.display_directory is not None:
                self.display_directory.cleanup()
            self.commands.close()
