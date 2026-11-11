"""Real interactive lifecycle/routing captures, after the core HTTP baseline.

All mutations use Dockistrate. The Python echo fixture is application content,
mounted into a disposable backend through its documented Docker-options flag.
Docker is used directly only to pull that fixture image and inspect runtime.
"""

import csv
import hashlib
import json
from pathlib import Path
import re
import shutil

from .ui import MENU_END, visible_text


DOMAIN = r"^example\.com(?:\s|$)"
MANUAL = r"^Enter manually\.\.\."
KEEP = r"^Keep current"


def menu(choice, prompt=None):
    if choice.endswith("$"):
        choice = choice[:-1] + r"(?: \(current\))?$"
    return ("menu", choice, prompt)


def text(prompt, value):
    # Generic prompts append examples/defaults on later lines before the colon.
    if prompt.endswith(": "):
        prompt = prompt[:-2] + r"[\s\S]*: "
    return ("text", prompt, value)


def run_command(ctx, command, steps=(), *, journey=None, require=(), preview=False,
                confirmations=(), review_require=()):
    with ctx.ui(journey or command, command=command) as ui:
        ui.command(command)
        for kind, first, second in steps:
            if kind == "menu":
                ui.menu(first, prompt=second, first_match=True)
            else:
                ui.text(first, second)
        readonly = command.startswith(("list-", "show-")) or command == "validate-domain-config"
        if not readonly and not preview:
            ui.menu(r"^Run$", prompt="Review", require=review_require,
                    title="Review and run " + command)
            if command.startswith("remove-"):
                ui.text(r"Type YES to run this destructive command: ", "YES",
                        title="Confirm removal")
        for prompt, value in confirmations:
            ui.text(prompt, value, title="Confirm container removal")
        return ui.finish(require=require, title=command + " result")


def applied(ctx, domain, filename):
    path = ctx.tool / "state/domains" / domain / "runtime/applied" / filename
    with path.open(newline="") as source:
        return list(csv.DictReader(source))


def verify_rows(ctx, label, domain, filename, predicate):
    rows = applied(ctx, domain, filename)
    (ctx.evidence / (ctx.slug(label) + ".json")).write_text(json.dumps(rows, indent=2) + "\n")
    assert predicate(rows), (label, rows)
    ctx.proof(label, file=f"state/domains/{domain}/runtime/applied/{filename}", rows=rows)


def inspect(ctx, domain="example.com", field="{{.State.Status}}"):
    return ctx.run(["docker", "inspect", "--format", field, "backend-" + domain],
                   label="inspect-" + domain).strip()


def verify_state(ctx, label, domain, expected):
    observed = inspect(ctx, domain)
    assert observed == expected, (label, observed, expected)
    ctx.proof(label, container_state=observed)


def http_port(ctx, label, port, domain="example.com", path="/", expected=200):
    output = ctx.terminal_command(label, ["curl", "--noproxy", "*", "-sS", "--max-time", "10", "-i",
                      "-H", "Host: " + domain, f"http://127.0.0.1:{port}{path}"], title="Verify the application response")
    assert re.search(r"^HTTP/\S+ " + str(expected) + r"\b", output, re.M), output
    ctx.proof(label, http_status=expected, port=port, domain=domain)
    return output


def add_port(ctx, domain, listen, upstream, protocol="HTTP", journey="ports-http"):
    steps = [menu(r"^" + re.escape(domain) + r"(?:\s|$)"), menu(MANUAL),
             text(r"Listen port: ", str(listen)), menu(MANUAL),
             text(r"Backend container port: ", str(upstream)), menu("^" + protocol + "$")]
    if protocol == "HTTP":
        steps.append(menu(r"^no(?:\s|$)"))
    return run_command(ctx, "add-port", steps, journey=journey)


def navigation(ctx):
    run_command(ctx, "list-port-mappings", journey="navigation-search", require=["example.com"])
    with ctx.ui("navigation-help") as ui:
        raw = ui.expect(MENU_END)
        ctx.capture(ui, "Home", visible_text(raw), "menu")
        ui.send("?")
        raw = ui.expect(r"Enter return  Esc return  Q return")
        ctx.capture(ui, "Contextual help", visible_text(raw), "help")
        ui.send("\n")
        ui.start(r"^Advanced command browser$")
        ui.menu(r"^Back to home$", title="Return from command categories")
        ui.quit()
    with ctx.ui("navigation-favorites", command="list-port-mappings") as ui:
        ui.start(r"^Recent commands$")
        ui.menu(r"List Port Mappings \(list-port-mappings\)", first_match=True)
        ui.menu(r"^Add to favorites$")
        ui.menu(r"^Back$")
        ui.start(r"^Favorites$")
        ui.menu(r"List Port Mappings \(list-port-mappings\)", first_match=True)
        ui.menu(r"^Run command$")
        ui.finish(require=["example.com"], title="Favorite command result")
    favorites = ctx.tool / "state/config/interactive_favorites.csv"
    assert "list-port-mappings" in favorites.read_text()
    ctx.proof("favorite-saved", file="state/config/interactive_favorites.csv")
    with ctx.ui("navigation-remove-favorite") as ui:
        ui.start(r"^Favorites$")
        ui.menu(r"List Port Mappings \(list-port-mappings\)", first_match=True)
        ui.menu(r"^Remove from favorites$")
        ui.quit()
    assert "list-port-mappings" not in favorites.read_text()
    before = applied(ctx, ctx.domain, "backend.csv")
    with ctx.ui("navigation-back-review-cancel", command="replace-backend-network") as ui:
        ui.command("replace-backend-network")
        ui.menu(DOMAIN)
        ui.menu(r"^Back$", title="Back to backend selection")
        ui.menu(DOMAIN)
        ui.menu(r"^" + re.escape(ctx.network) + r"(?:\s|$)")
        ui.menu(r"^Edit previous answers$", title="Edit previous answers")
        ui.menu(DOMAIN)
        ui.menu(r"^" + re.escape(ctx.network) + r"(?:\s|$)")
        ui.menu(r"^Cancel$", title="Cancel before running")
        ui.menu(r"^Back$", title="Return from search")
        ui.quit()
    assert applied(ctx, ctx.domain, "backend.csv") == before
    ctx.proof("navigation-cancel-preserves-backend")


def prerequisite_guidance(ctx):
    """Follow the real missing-setup routes before the fixture exists."""
    owner = ctx.tool / "state/domains" / ctx.domain
    assert not (owner / "runtime/applied/backend.csv").exists()
    with ctx.ui("navigation-missing-backend", command="stop-backend") as ui:
        ui.command("stop-backend")
        ui.menu(r"^Add backend now$", prompt="Missing setup", require=["no backends are configured"],
                title="Create the missing backend")
        ui.command_name = "add-backend"
        ui.menu(r"^Enter domain$")
        ui.text(r"Domain: ", ctx.domain)
        ui.menu(r"^HTTP$")
        ui.menu(r"^" + re.escape(ctx.network) + r"(?:\s|$)")
        ui.menu(MANUAL)
        ui.text(r"Docker image: ", ctx.image)
        ui.menu(r"^80$", first_match=True)
        ui.menu(r"^Use default: 80$")
        ui.menu(r"^Disabled$")
        ui.menu(r"^Do not expose$", title="Create the backend before exposing a port")
        ui.text(r"Additional docker run options \(optional; finish with empty line\): ", "")
        ui.menu(r"^Run$", prompt="Review command", require=["add-backend"])
        ui.finish(title="The suggested backend creation completes")
    assert not applied(ctx, ctx.domain, "ports.csv"), "Unexposed backend unexpectedly has a listener"
    verify_state(ctx, "missing-backend-created", ctx.domain, "running")

    with ctx.ui("navigation-missing-port", command="remove-port") as ui:
        ui.command("remove-port")
        ui.menu(r"^Add port now$", prompt="Missing setup", require=["no port mappings are configured"],
                title="Create the missing port mapping")
        ui.command_name = "add-port"
        ui.menu(DOMAIN)
        ui.menu(r"^80$", first_match=True)
        ui.menu(r"^80$", first_match=True)
        ui.menu(r"^HTTP$")
        ui.menu(r"^no(?:\s|$)")
        ui.menu(r"^Run$", prompt="Review command", require=["add-port"])
        ui.finish(title="The suggested HTTP port creation completes")
    ctx.request("suggested-port-default-deny", 403)
    ctx.cli("suggested-port-public-demo", "set-backend-acl-policy", ctx.domain, "allow")
    ctx.request("suggested-port-http-success")
    ctx.proof("missing-prerequisites-created", domain=ctx.domain, listener=80,
              initial_backend_unexposed=True, http_status=200)

    for command, kind, action in (
        ("remove-cert", "certificates", "Add certificate now"),
        ("update-backend-header", "headers", "Add backend header now"),
        ("disable-backend-mtls", "mtls", "Enable backend mTLS now"),
        ("disable-acl", "acl", "Add ACL rule now"),
        ("disable-security-rule", "security-rule", "Add security rule now"),
    ):
        before = ctx.runtime_snapshot()
        with ctx.ui("navigation-missing-" + kind, command=command) as ui:
            ui.command(command)
            ui.menu(r"^Return to previous menu$", prompt="Missing setup", require=[action],
                    title="Return from missing " + kind + " guidance")
            ui.menu(r"^Back$", title="Return from command search")
            ui.quit()
        assert ctx.runtime_snapshot() == before, "Returning from guidance changed runtime"
        ctx.proof("missing-" + kind + "-guidance", suggested_action=action,
                  runtime_unchanged=True)


def manual_backup_restore(ctx):
    """Use a genuine exported backup when the local backup picker is empty."""
    ctx.cli("manual-backup-compression", "set-backup-compression", "true")
    ctx.cli("manual-backup-create", "create-backup", "before-manual-restore")
    backup = Path((ctx.tool / "state/backups/last_full_backup.txt").read_text().strip())
    assert backup.is_file() and backup.name.endswith(".tar.gz"), "Expected a real compressed backup"
    digest = hashlib.sha256(backup.read_bytes()).hexdigest()
    external = Path("/opt/dockistrate-demo-fixtures/manual-restore.tar.gz")
    assert not external.exists(), "The external demonstration backup already exists"
    # Dockistrate has no backup-transfer command. Move only this freshly created
    # archive to represent receiving a backup from another location.
    ctx.run(["mv", backup, external], label="move-backup-to-external-fixture")
    assert hashlib.sha256(external.read_bytes()).hexdigest() == digest
    ctx.cli("manual-restore-later-change", "add-backend-header", ctx.domain,
            "response", "X-Restore-Manual", "changed")
    # Mutations also create rollback snapshots even with auto-backups disabled.
    # Preserve this fresh VM's complete backup history externally after the last
    # fixture mutation, so the receiving-machine example has no local choices.
    exported_history = external.parent / "exported-local-backups"
    exported_history.mkdir(mode=0o700)
    local_backups = ctx.tool / "state/backups"
    transferred = []
    for item in sorted(local_backups.iterdir()):
        transferred.append(item.name)
        ctx.run(["mv", item, exported_history / item.name], label="export-demo-backup-history")
    assert not list(local_backups.iterdir()), "Manual-path guidance requires an empty local backup directory"
    ctx.proof("local-backup-history-transferred", entries=transferred, deleted_entries=0)
    before = ctx.terminal_command("manual-restore-before", ["curl", "--noproxy", "*", "-sS", "-D", "-",
                                 "-o", "/dev/null", "-H", "Host: example.com", "http://127.0.0.1/"],
                                 require=["HTTP/1.1 200", "X-Restore-Manual: changed"],
                                 title="The later header is active before restoration")
    assert "x-restore-manual: changed" in before.lower()
    with ctx.ui("navigation-restore-manual", command="restore-backup") as ui:
        ui.command("restore-backup")
        ui.menu(r"^Enter backup path manually$", prompt="Missing setup", require=["no backups are available"],
                title="Use a backup outside the local backup folder")
        # With no local choices the generic collector displays a text prompt.
        ui.text(r": $", str(external), title="Enter the received backup path")
        ui.text(r": $", "", title="Keep the optional backend details empty")
        ui.menu(r"^Run$", prompt="Review command", require=["restore-backup", "manual-restore.tar.gz"])
        ui.text(r"\(y/n\): ", "y", title="Confirm restoring the received backup")
        ui.finish(title="The external backup is restored")
    ctx.request("manual-restore-http-success")
    after = ctx.terminal_command("manual-restore-after", ["curl", "--noproxy", "*", "-sS", "-D", "-",
                                "-o", "/dev/null", "-H", "Host: example.com", "http://127.0.0.1/"],
                                require=["HTTP/1.1 200"], title="The restored response no longer has the later header")
    assert "x-restore-manual:" not in after.lower(), "Manual restore kept a post-backup header"
    assert hashlib.sha256(external.read_bytes()).hexdigest() == digest, "Restore modified its source backup"
    ctx.proof("external-backup-restored", source_backup_sha256=digest,
              source_unchanged=True, later_header_removed=True, http_status=200)
    ctx.check_config("manual-restore-config")


def pending_edit_review_apply(ctx):
    """Review pending files, apply them, then recollect the requested command."""
    owner = ctx.tool / "state/domains" / ctx.domain
    draft = owner / "config/headers.csv"
    active = owner / "runtime/applied/headers.csv"
    before_applied = active.read_bytes()
    with draft.open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    rows.append({"header_type": "response", "header_name": "X-Interactive-Draft", "header_value": "activated"})
    with draft.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=["header_type", "header_name", "header_value"], lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    draft_hash = hashlib.sha256(draft.read_bytes()).hexdigest()
    before_runtime = ctx.runtime_snapshot()
    ctx.request("pending-review-before", header=False)
    with ctx.ui("pending-edit-review-apply", command="restart-backend") as ui:
        ui.command("restart-backend")
        ui.menu(DOMAIN)
        ui.menu(r"^Review file changes$", prompt="Unapplied file changes",
                title="Review the pending file changes before restarting")
        review = ui.expect("Unapplied file changes for " + re.escape(ctx.domain))
        assert "headers.csv" in review, "Pending review omitted the edited file"
        # The current menu immediately clears the preview while redisplaying
        # its choices. Verify the original bytes and keep their excerpt in
        # events; the next screenshot shows the actual returned menu.
        preview_excerpt = visible_text(review.rsplit("\x1b[H", 1)[0])
        assert "headers.csv" in preview_excerpt, "Captured pending-review excerpt omitted the edited file"
        preview_file = ctx.evidence / (ui.journey + ".review-preview.txt")
        preview_file.write_text(preview_excerpt.rstrip() + "\n")
        ui.record("cleared-review-output", output=preview_excerpt,
                  excerpt_file=str(preview_file.relative_to(ctx.output)))
        assert active.read_bytes() == before_applied, "Review changed applied files"
        assert hashlib.sha256(draft.read_bytes()).hexdigest() == draft_hash, "Review changed the draft"
        assert ctx.runtime_snapshot() == before_runtime, "Review changed running containers or proxy processes"
        ctx.request("pending-review-still-inactive", header=False)
        ctx.proof("pending-file-review-unchanged", applied_unchanged=True,
                  draft_unchanged=True, runtime_unchanged=True,
                  preview_excerpt=str(preview_file.relative_to(ctx.output)))
        ui.menu(r"^Apply file changes$", title="Apply the pending files through the nested review")
        ui.menu(r"^Run$", prompt="Review command", require=["apply-domain-config"],
                title="Confirm applying the pending header")
        result = visible_text(ui.expect(r"File changes applied\. Review the command arguments again\."))
        ctx.capture_pages(ui, "Pending files applied; collect the original command again", result, "result")
        assert active.read_bytes() == draft.read_bytes(), "Apply did not activate the draft"
        ctx.request("pending-apply-active-before-restart", header=True)
        ui.command_name = "restart-backend"
        ui.menu(DOMAIN, title="Select the backend again after applying files")
        ui.menu(r"^Run$", prompt="Review command", require=["restart-backend"],
                title="Review the recollected restart command")
        ui.finish(title="The original restart command completes after recollection")
    verify_state(ctx, "pending-apply-restarted", ctx.domain, "running")
    ctx.request("pending-apply-after-restart", header=True)
    ctx.terminal_command("pending-edit-active-response", ["curl", "--noproxy", "*", "-sS", "-D", "-",
                         "-o", "/dev/null", "-H", "Host: example.com", "http://127.0.0.1/"],
                         require=["HTTP/1.1 200", "X-Interactive-Draft: activated"],
                         title="The applied header remains active after restarting")
    ctx.check_config("pending-edit-final-config")
    ctx.proof("pending-apply-recollect-restart", draft_sha256=draft_hash,
              arguments_recollected=True, active_header="X-Interactive-Draft: activated")


def input_branches(ctx):
    prerequisite_guidance(ctx)
    manual_backup_restore(ctx)
    pending_edit_review_apply(ctx)


def backend_lifecycle(ctx):
    run_command(ctx, "list-backends", require=["example.com"])
    run_command(ctx, "stop-backend", [menu(DOMAIN)], journey="backend-lifecycle-stop")
    verify_state(ctx, "backend-stopped", ctx.domain, "exited")
    run_command(ctx, "start-backend", [menu(DOMAIN)], journey="backend-lifecycle-start")
    verify_state(ctx, "backend-started", ctx.domain, "running")
    ctx.request("backend-started-request")
    run_command(ctx, "restart-backend", [menu(DOMAIN)], journey="backend-lifecycle-restart")
    verify_state(ctx, "backend-restarted", ctx.domain, "running")
    ctx.request("backend-restarted-request")
    before = inspect(ctx, field="{{.Id}}")
    run_command(ctx, "update-backend", [menu(DOMAIN), menu(MANUAL),
                text(r"Container image: ", ctx.image), menu(KEEP), menu(KEEP),
                menu(r"^" + re.escape(ctx.network) + r"(?:\s|$)")], journey="backend-update")
    after = inspect(ctx, field="{{.Id}}")
    assert before != after, "Explicit image replacement did not change container identity"
    ctx.proof("backend-image-replaced", previous_id=before, replacement_id=after)
    ctx.request("backend-update-request")
    run_command(ctx, "replace-backend-network", [menu(DOMAIN), menu(MANUAL),
                text(r"Docker network: ", "docs-secondary")], journey="backend-network")
    verify_rows(ctx, "network-applied", ctx.domain, "backend.csv",
                lambda rows: rows[0]["network"] == "docs-secondary")
    assert "docs-secondary" in inspect(ctx, field="{{json .NetworkSettings.Networks}}")
    ctx.request("network-move-request")
    ctx.cli("restore-network", "replace-backend-network", ctx.domain, ctx.network)


def proxy_lifecycle(ctx):
    run_command(ctx, "update-nginx-config", journey="proxy-regenerate")
    ctx.check_config("proxy-regenerate-check")
    run_command(ctx, "stop-nginx", journey="proxy-stop")
    state = ctx.run(["docker", "inspect", "--format", "{{.State.Status}}", "nginx-proxy"],
                    label="proxy-stopped").strip()
    assert state == "exited", state
    ctx.proof("proxy-stopped", container_state=state)
    start_steps = [menu(KEEP), menu(KEEP)]
    run_command(ctx, "start-nginx", start_steps, journey="proxy-start")
    ctx.request("proxy-started-request")
    # Local image aliases are fixture setup unsupported by Dockistrate. Keep
    # the already running, compatible image bytes; change only its reference.
    original_image = ctx.run(["docker", "inspect", "--format", "{{.Config.Image}}", "nginx-proxy"],
                             label="proxy-original-image").strip()
    custom_image = "docs-nginx:review"
    ctx.run(["docker", "tag", original_image, custom_image], label="proxy-fixture-image-alias")
    run_command(ctx, "start-nginx", [menu(MANUAL), text(r"nginx image: ", custom_image),
                menu(MANUAL), text(r"Extra Docker run options: ", "--memory 256m"), text(r"> $", "")],
                journey="proxy-start-custom",
                review_require=(r"nginx image: docs-nginx:review", r"Extra Docker run options: --memory 256m"))
    proxy_details = ["docker", "inspect", "--format", "{{.Config.Image}}|{{.HostConfig.Memory}}", "nginx-proxy"]
    assert ctx.run(proxy_details, label="proxy-custom-runtime").strip() == custom_image + "|268435456"
    ctx.terminal_command("proxy-custom-verified", proxy_details,
                         require=(r"docs-nginx:review\|268435456",),
                         title="Verify the selected proxy image and memory limit")
    ctx.request("proxy-custom-request")
    ctx.check_config("proxy-custom-config")
    http_port(ctx, "proxy-custom-response", 80)
    run_command(ctx, "start-nginx", [menu(KEEP), menu(r"^Clear current options$")],
                journey="proxy-start-clear",
                review_require=(r"Extra Docker run options: \(clear\)", r"--docker-opts ''"))
    assert ctx.run(proxy_details, label="proxy-cleared-runtime").strip() == custom_image + "|0"
    ctx.terminal_command("proxy-clear-verified", proxy_details,
                         require=(r"docs-nginx:review\|0",),
                         title="Verify cleared options and the retained proxy image")
    ctx.request("proxy-cleared-request")
    ctx.check_config("proxy-cleared-config")
    http_port(ctx, "proxy-cleared-response", 80)
    ctx.cli("proxy-restore-image", "start-nginx", "--nginx-image", original_image)
    ctx.request("proxy-restored-image-request")
    run_command(ctx, "remove-nginx", journey="proxy-remove")
    remaining = ctx.run(["docker", "ps", "-aq", "--filter", "name=^/nginx-proxy$"],
                        label="proxy-removed").strip()
    assert not remaining, remaining
    ctx.proof("proxy-container-removed")
    ctx.cli("proxy-restore", "start-nginx")
    ctx.request("proxy-recreated-request")


def hosts(ctx):
    alias = "www.example.com"
    run_command(ctx, "add-host-alias", [menu(DOMAIN), menu(r"^Enter alias$"),
                text(r"Alias \(blank=Back\): ", alias)], journey="hosts-alias")
    run_command(ctx, "list-host-aliases", [menu(DOMAIN)], require=[re.escape(alias)])
    http_port(ctx, "alias-request", 80, domain=alias)
    run_command(ctx, "remove-host-alias", [text(r"Alias: ", alias)])
    result = ctx.cli("verify-alias-removed", "list-host-aliases", ctx.domain)
    assert alias not in result, result
    ctx.proof("alias-removed")
    host = "app.example.com"
    run_command(ctx, "add-dedicated-host", [text(r"Hostname: ", host), menu(DOMAIN)] +
                [menu(r"^yes(?:\s|$)")] * 5, journey="hosts-dedicated")
    run_command(ctx, "list-dedicated-hosts", [menu(DOMAIN)], require=[re.escape(host)])
    run_command(ctx, "show-dedicated-host-inherit", [menu(r"^app\.example\.com(?:\s|$)")],
                require=["headers", "yes"])
    http_port(ctx, "dedicated-host-request", 80, domain=host)
    run_command(ctx, "set-dedicated-host-inherit", [menu(r"^app\.example\.com(?:\s|$)"),
                menu(r"^headers(?:\s|$)"), menu(r"^no(?:\s|$)")], journey="hosts-inheritance")
    verify_rows(ctx, "host-inheritance-off", host, "inheritance.csv", lambda rows: rows[0]["headers"] == "no")
    ctx.request("dedicated-host-no-inherited-headers", domain=host, header=False)
    run_command(ctx, "remove-dedicated-host", [menu(r"^app\.example\.com(?:\s|$)")])
    result = ctx.cli("verify-dedicated-removed", "list-dedicated-hosts", ctx.domain)
    assert host not in result, result
    ctx.proof("dedicated-host-removed")


def ports(ctx):
    add_port(ctx, ctx.domain, 8080, 80)
    http_port(ctx, "http-extra-port", 8080)
    run_command(ctx, "update-port", [menu(DOMAIN), menu(r"^8080\b"), menu(MANUAL),
                text(r"New listen port: ", "8081"), menu(KEEP), menu(KEEP), menu(KEEP)],
                journey="ports-update")
    verify_rows(ctx, "http-port-moved", ctx.domain, "ports.csv",
                lambda rows: any(r["listen_port"] == "8081" for r in rows)
                and not any(r["listen_port"] == "8080" for r in rows))
    http_port(ctx, "http-moved-port", 8081)
    run_command(ctx, "remove-port", [menu(DOMAIN), menu(r"^8081\b")], journey="ports-remove")
    verify_rows(ctx, "http-port-removed", ctx.domain, "ports.csv",
                lambda rows: not any(r["listen_port"] == "8081" for r in rows))
    run_command(ctx, "set-port-redirect", [menu(DOMAIN), menu(r"^80\b"),
                menu(r"^on(?:\s|$)"), menu(r"Moved Permanently")], journey="ports-redirect")
    response = http_port(ctx, "http-redirect", 80, expected=301)
    headers = response.lower()
    assert "location: https://example.com/" in headers, headers
    run_command(ctx, "remove-port-redirect", [menu(DOMAIN), menu(r"^80\b")], journey="ports-redirect-remove")
    http_port(ctx, "http-redirect-removed", 80)


def paths(ctx):
    steps = [menu(DOMAIN), menu(r"^80\b"), text(r"Path prefix: ", "/api"),
             menu(r"^inherit(?:\s|$)"), text(r"Redirect[^\n]*: ", "inherit"),
             text(r"Header set[^\n]*: ", "none"), menu(r"^Prefix$"), menu(r"^10$"),
             menu(MANUAL), text(r"Upstream target: ", "80"), menu(r"^Strip prefix$"),
             menu(MANUAL), text(r"Reason: ", "API demo"), menu(r"^auto$")]
    run_command(ctx, "add-path-option", steps, journey="path-routing",
                review_require=(r"Path prefix: /api", r"Path priority: 10",
                                r"Upstream target: 80", r"Path rewrite: strip-prefix", r"Reason: API demo"))
    run_command(ctx, "list-path-options", [menu(DOMAIN), text(r"Listen port: ", "80")], require=["/api"])
    http_port(ctx, "path-prefix-rewrite", 80, path="/api/")
    steps = [menu(DOMAIN), menu(r"^80\b"), menu(r"^/api(?:\s|$)"),
             text(r"Path prefix: ", "/service"), text(r"new nginx port: ", ""),
             menu(r"^inherit(?:\s|$)"), text(r"Redirect[^\n]*: ", "inherit"),
             text(r"Header set[^\n]*: ", "none"), menu(r"^Prefix$"), menu(r"^50$"),
             menu(MANUAL), text(r"Upstream target: ", "80"), menu(r"^Strip prefix$"),
             menu(MANUAL), text(r"Reason: ", "Service demo"), menu(r"^auto$")]
    run_command(ctx, "update-path-option", steps, journey="path-update",
                review_require=(r"Current path prefix: /api", r"New path prefix: /service",
                                r"Path priority: 50", r"Upstream target: 80", r"Reason: Service demo"))
    http_port(ctx, "updated-prefix-rewrite", 80, path="/service/")
    verify_rows(ctx, "path-updated", ctx.domain, "paths.csv",
                lambda rows: any(r["path_prefix"] == "/service" and r["priority"] == "50" for r in rows))
    run_command(ctx, "remove-path-option", [menu(DOMAIN), menu(r"^80\b"),
                menu(r"^/service(?:\s|$)")], journey="path-remove")
    verify_rows(ctx, "path-removed", ctx.domain, "paths.csv", lambda rows: not rows)
    ctx.cli("fixture-path-one", "add-path-option", ctx.domain, "80", "/one", "--target", "80")
    ctx.cli("fixture-path-two", "add-path-option", ctx.domain, "443", "/two", "--target", "80")
    run_command(ctx, "remove-all-path-options", [menu(DOMAIN)], journey="path-remove-all")
    verify_rows(ctx, "all-paths-removed", ctx.domain, "paths.csv", lambda rows: not rows)


FIXTURE = r'''#!/usr/bin/env python3
import base64
import hashlib
import http.server
import socketserver
import threading

class HTTP(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get('Upgrade', '').lower() == 'websocket':
            accept = base64.b64encode(hashlib.sha1((self.headers['Sec-WebSocket-Key'] +
                     '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', accept)
            self.end_headers()
            self.wfile.write(b'\x81\x09docs-pong')
            self.wfile.flush()
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'docs-http-ok\n')
class TCP(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.sendall(b'docs-tcp:' + self.request.recv(1024))
class UDP(socketserver.BaseRequestHandler):
    def handle(self):
        payload, connection = self.request
        connection.sendto(b'docs-udp:' + payload, self.client_address)
for service, port, handler in [(http.server.ThreadingHTTPServer, 8080, HTTP),
                              (socketserver.ThreadingTCPServer, 9090, TCP),
                              (socketserver.ThreadingUDPServer, 9091, UDP)]:
    server = service(('0.0.0.0', port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
threading.Event().wait()
'''



PROBE = r'''import socket
import sys

mode = sys.argv[1]
if mode in ('websocket', 'websocket-disabled'):
    with socket.create_connection(('127.0.0.1', 18080), timeout=10) as connection:
        connection.sendall(b'GET / HTTP/1.1\r\nHost: protocol.example.com\r\nUpgrade: websocket\r\n'
                           b'Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n'
                           b'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n')
        response = b''
        expected = b'docs-pong' if mode == 'websocket' else b'docs-http-ok'
        while expected not in response:
            chunk = connection.recv(4096)
            if not chunk:
                break
            response += chunk
    print(response.decode(errors='replace'))
    if mode == 'websocket':
        assert b' 101 ' in response and b'docs-pong' in response, response
    else:
        assert b' 200 ' in response and b'docs-http-ok' in response, response
elif mode == 'tcp':
    with socket.create_connection(('127.0.0.1', 19090), timeout=10) as connection:
        connection.sendall(b'ping')
        response = connection.recv(1024)
    print(response.decode())
    assert response == b'docs-tcp:ping', response
elif mode == 'udp':
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
        connection.settimeout(10)
        connection.sendto(b'ping', ('127.0.0.1', 19091))
        response, _ = connection.recvfrom(1024)
    print(response.decode())
    assert response == b'docs-udp:ping', response
else:
    raise ValueError(mode)
'''


def application_protocols(ctx):
    fixture = ctx.evidence / "demo-service.py"
    fixture.write_text(FIXTURE)
    fixture.chmod(0o755)
    client = ctx.evidence / "protocol-client.py"
    client.write_text(PROBE)
    ctx.proof("application-fixture", file=str(fixture.relative_to(ctx.output)),
              sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),
              description="Disposable HTTP/WebSocket/TCP/UDP server; application fixture, not a Docker mock")
    ctx.run(["docker", "pull", "python:3-alpine"], label="fixture-python-image", timeout=300)
    options = f"--mount type=bind,src={fixture},dst=/demo-service.py,readonly --entrypoint /demo-service.py"
    ctx.cli("fixture-protocol-backend", "add-backend", "protocol.example.com", "python:3-alpine",
            "8080", "http", "--no-expose", "--docker-opts", options)
    ctx.cli("fixture-protocol-allow", "set-backend-acl-policy", "protocol.example.com", "allow")
    add_port(ctx, "protocol.example.com", 18080, 8080, journey="ports-websocket-http")
    http_port(ctx, "protocol-http", 18080, domain="protocol.example.com")
    run_command(ctx, "enable-ws", [menu(r"^protocol\.example\.com(?:\s|$)"), text(r"Listen port: ", "18080")],
                journey="ports-websocket-enable")
    ctx.terminal_command("websocket-upgrade-and-frame", ["python3", client, "websocket"],
                         require=["101", "docs-pong"], title="WebSocket upgrade and response frame")
    run_command(ctx, "disable-ws", [menu(r"^protocol\.example\.com(?:\s|$)"), text(r"Listen port: ", "18080")],
                journey="ports-websocket-disable")
    verify_rows(ctx, "websocket-disabled", "protocol.example.com", "ports.csv",
                lambda rows: any(r["listen_port"] == "18080" and r["websocket"] == "no" for r in rows))
    ctx.terminal_command("websocket-upgrade-disabled", ["python3", client, "websocket-disabled"],
                         require=["200", "docs-http-ok"], title="WebSocket off returns the ordinary HTTP response")
    add_port(ctx, "protocol.example.com", 19090, 9090, "TCP", journey="ports-stream-tcp")
    ctx.terminal_command("tcp-proxy-response", ["python3", client, "tcp"],
                         require=["docs-tcp:ping"], title="TCP application responds through the proxy")
    add_port(ctx, "protocol.example.com", 19091, 9091, "UDP", journey="ports-stream-udp")
    ctx.terminal_command("udp-proxy-response", ["python3", client, "udp"],
                         require=["docs-udp:ping"], title="UDP application responds through the proxy")
    ctx.check_config("stream-and-websocket-config")
    run_command(ctx, "remove-backend", [menu(r"^protocol\.example\.com(?:\s|$)")],
                journey="backend-remove", confirmations=[(r"Remove container [^\n]*\(y/n\): ", "y")])
    result = ctx.cli("verify-protocol-backend-removed", "list-backends")
    assert "protocol.example.com" not in result, result
    ctx.proof("protocol-backend-removed")


def domain_templates(ctx):
    draft = "draft.example.com"
    run_command(ctx, "init-domain-config", [text(r"Domain: ", draft),
                menu(r"^Certificates without a backend container$")], journey="domain-init")
    root = ctx.tool / "state/domains" / draft
    assert (root / "config/domain.csv").is_file()
    assert not (root / "runtime/applied/domain.csv").exists()
    ctx.proof("domain-template-only", domain=draft, container_started=False)
    # Current-state migration is an honest no-op demonstration, not a legacy conversion.
    run_command(ctx, "migrate-state", [menu(r"^Review changes without applying them$"),
                text(r"Backend details CSV path \(optional\): ", "")],
                journey="domain-migrate-current", preview=True, require=["already uses schema 5"])
    ctx.proof("migration-current-state-noop", schema=5,
              limitation="Does not demonstrate conversion of a legacy state directory")


def bulk(ctx):
    # Two configured containers make the all-backend scope observable.
    ctx.cli("fixture-second-backend", "add-backend", "second.example.com", ctx.image,
            "80", "http", "--no-expose")
    domains = [ctx.domain, "second.example.com"]
    run_command(ctx, "stop-all-backends", journey="backend-bulk-stop")
    for domain in domains:
        verify_state(ctx, "bulk-stop-" + domain, domain, "exited")
    run_command(ctx, "start-all-backends", journey="backend-bulk-start")
    for domain in domains:
        verify_state(ctx, "bulk-start-" + domain, domain, "running")
    ctx.request("bulk-start-request")
    run_command(ctx, "restart-all-backends", journey="backend-bulk-restart")
    for domain in domains:
        verify_state(ctx, "bulk-restart-" + domain, domain, "running")
    ctx.request("bulk-restart-request")
    run_command(ctx, "remove-all-backends", journey="backend-bulk-remove",
                confirmations=[(r"Remove container [^\n]*\(y/n\): ", "y")] * len(domains))
    remaining = ctx.cli("verify-bulk-removed", "list-backends")
    assert all(domain not in remaining for domain in domains), remaining
    ctx.proof("all-backends-removed", domains=domains)


LEGACY_STATE = r'''set -Eeuo pipefail
cd "$1"
source lib/config.sh
source lib/utils.sh
source lib/domain_config.sh
CERTS_DIR="$STATE_DIR/certs"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR/nginx_conf/conf.d" "$CERTS_DIR"
config_reset_defaults
ENABLE_AUTO_BACKUPS=false
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
state_security_rules_use_schema 1
state_csv_ensure_all_state_files
printf '1\n' >"$CONFIG_DIR/state_schema_version"
state_backend_ports_row_backend legacy.example.com 172.20.0.3:80 "$DEFAULT_NETWORK" >>"$BACKEND_PORTS_FILE"
state_backend_ports_row_port legacy.example.com 18181 80 http none no off '' >>"$BACKEND_PORTS_FILE"
csv_join_row legacy.example.com response X-Migration 'Retain, "exactly"' >>"$BACKEND_HEADERS_FILE"
printf '# Existing legacy proxy configuration; storage migration must preserve it.\n' >"$CONFIG_DIR/nginx_conf/conf.d/backends.conf"
printf 'domain,image,state\nlegacy.example.com,nginx:alpine,stopped\n' >backend-details.csv
printf 'Prepared an isolated schema-1 state fixture with explicit stopped backend details.\n'
'''


def legacy_migration(ctx):
    original = ctx.tool
    migration = original.parent / "dockistrate-demo-fixtures" / "migration"
    migration.mkdir()
    for name in ("lib", "config", "completion"):
        shutil.copytree(original / name, migration / name)
    for name in ("dockistrate.sh", "VERSION"):
        shutil.copy2(original / name, migration / name)
    source_hashes = {}
    for item in migration.rglob("*"):
        if item.is_file():
            relative = item.relative_to(migration)
            digest = hashlib.sha256(item.read_bytes()).hexdigest()
            assert digest == hashlib.sha256((original / relative).read_bytes()).hexdigest()
            source_hashes[str(relative)] = digest
    (ctx.evidence / "migration-source-hashes.json").write_text(json.dumps(source_hashes, indent=2) + "\n")
    ctx.proof("migration-unchanged-source-copy", source_commit=ctx.source_commit,
              compared_source_files=len(source_hashes), checkout=str(migration))
    ctx.run(["bash", "-c", LEGACY_STATE, "migration-fixture", migration], label="legacy-migration-fixture")

    def inventory():
        identifiers = ctx.run(["docker", "ps", "-aq", "--no-trunc"],
                              label="migration-container-ids").splitlines()
        containers = []
        if identifiers:
            containers = sorted(ctx.run(["docker", "inspect", "--format",
                "{{.Id}}|{{.Name}}|{{.State.Status}}|{{.State.StartedAt}}|{{.State.FinishedAt}}|{{.RestartCount}}",
                *identifiers], label="migration-container-lifecycle").splitlines())
        networks = sorted(ctx.run(["docker", "network", "ls", "--no-trunc", "--format", "{{.ID}}|{{.Name}}"],
                                  label="migration-network-inventory").splitlines())
        return {"containers": containers, "networks": networks}

    def configuration_fingerprint():
        directory = migration / "state/config"
        return {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in directory.rglob("*") if path.is_file()
                and not path.name.startswith("interactive_")}

    before = configuration_fingerprint()
    before_runtime = inventory()
    details = str(migration / "backend-details.csv")
    legacy_proxy = migration / "state/config/nginx_conf/conf.d/backends.conf"
    legacy_ports = migration / "state/config/backend_ports.csv"
    proxy_before, ports_before = legacy_proxy.read_bytes(), legacy_ports.read_bytes()
    try:
        ctx.tool = migration
        run_command(ctx, "migrate-state", [menu(r"^Review changes without applying them$"),
                    text(r"Backend details CSV path \(optional\): ", details)],
                    journey="domain-migrate-preview", preview=True,
                    require=[r"Migration preflight passed \(schema 1 -> 5\)", "legacy.example.com"])
        assert configuration_fingerprint() == before, "Migration preview changed legacy configuration"
        assert (migration / "state/config/state_schema_version").read_text().strip() == "1"
        assert not (migration / "state/domains").exists(), "Preview published domain directories"
        assert inventory() == before_runtime, "Migration preview changed Docker inventory"
        ctx.proof("legacy-migration-preview-preserves-state", source_schema=1,
                  configuration_sha256=before, docker_inventory=before_runtime)
        run_command(ctx, "migrate-state", [menu(r"^Apply changes$"),
                    text(r"Backend details CSV path \(optional\): ", details)],
                    journey="domain-migrate-apply", require=["State migrated to schema 5"])
        marker = (migration / "state/config/state_schema_version").read_text().strip()
        assert marker == "5", marker
        verify_rows(ctx, "legacy-applied-backend", "legacy.example.com", "backend.csv",
                    lambda rows: len(rows) == 1 and rows[0]["image"] == "nginx:alpine"
                    and rows[0]["container_port"] == "80" and rows[0]["state"] == "stopped")
        owner = migration / "state/domains/legacy.example.com"
        assert (owner / "config/backend.csv").read_bytes() == (owner / "runtime/applied/backend.csv").read_bytes()
        with (owner / "config/headers.csv").open(newline="") as source:
            headers = list(csv.DictReader(source))
        assert any(row["header_name"] == "X-Migration" and row["header_value"] == 'Retain, "exactly"'
                   for row in headers), headers
        assert legacy_proxy.read_bytes() == proxy_before, "Migration changed serving configuration"
        assert legacy_ports.read_bytes() == ports_before, "Migration changed legacy upstream addresses"
        assert inventory() == before_runtime, "Migration changed Docker inventory"
        for relative, expected in source_hashes.items():
            assert hashlib.sha256((migration / relative).read_bytes()).hexdigest() == expected
        ctx.terminal_command("migration-converted-files", ["cat", owner / "config/domain.csv",
                             owner / "config/backend.csv", owner / "runtime/applied/backend.csv",
                             owner / "config/headers.csv"],
                             require=["schema_version", "nginx:alpine", "stopped", "X-Migration"],
                             title="Editable and applied configuration after migration")
        ctx.proof("legacy-state-migrated", from_schema=1, to_schema=5,
                  editable_and_applied_match=True, source_unchanged=True,
                  proxy_configuration_unchanged=True, docker_inventory_unchanged=True)
    finally:
        ctx.tool = original


def run(ctx):
    navigation(ctx)
    backend_lifecycle(ctx)
    proxy_lifecycle(ctx)
    hosts(ctx)
    ports(ctx)
    paths(ctx)
    application_protocols(ctx)
    domain_templates(ctx)
    ctx.check_config("core-final-config")
    bulk(ctx)
    legacy_migration(ctx)


GROUPS = ("services", "hosts", "routing", "protocols", "migration", "branches")


def run_group(ctx, group):
    """Run one independent journey set in a fresh disposable checkout."""
    if group not in GROUPS:
        raise ValueError("Unknown core capture group: " + group)
    if group == "branches":
        input_branches(ctx)
        ctx.proof("core-group-complete", group=group)
        return
    ctx.ensure_backend(https=group != "migration")
    if group == "services":
        navigation(ctx)
        backend_lifecycle(ctx)
        proxy_lifecycle(ctx)
        bulk(ctx)
    elif group == "hosts":
        ctx.cli("fixture-inherited-response-header", "add-backend-header", ctx.domain,
                "response", "X-Interactive-Draft", "activated")
        ctx.request("fixture-inherited-header-present", header=True)
        hosts(ctx)
        ctx.check_config("hosts-final-config")
    elif group == "routing":
        ports(ctx)
        paths(ctx)
        ctx.check_config("routing-final-config")
    elif group == "protocols":
        application_protocols(ctx)
        ctx.check_config("protocols-final-config")
    elif group == "migration":
        domain_templates(ctx)
        legacy_migration(ctx)
    ctx.proof("core-group-complete", group=group)
