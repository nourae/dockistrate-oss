"""First application, HTTPS, request filtering, and explicit draft publication."""

import csv
import hashlib
import re


def domain_action(ctx, label, command, action=None):
    with ctx.ui(label, command=command) as ui:
        ui.start(r"^Domain configuration files$", r"^" + re.escape(ctx.command_alias(command)) + r"(?:\s|$)")
        ui.menu(r"^" + re.escape(ctx.domain) + r"(?:\s|$)", title="Select example.com")
        if action is not None:
            ui.menu(action, title="Choose preview or apply")
            if action == r"^Apply changes$":
                ui.menu(r"^Run$", prompt="Review command", title="Review and apply")
        return ui.finish()


def run(ctx):
    with ctx.ui("http-backend", command="add-backend") as ui:
        ui.start(r"^Add a new backend$")
        ui.menu(r"^Enter domain$", title="Enter a new domain")
        ui.text(r"Domain: ", ctx.domain, title="Name the application")
        ui.menu(r"^HTTP$", prompt="Protocol", title="Choose HTTP")
        ui.menu(r"^" + re.escape(ctx.network) + r"(?:\s|$)", prompt="Network", title="Use the default network")
        ui.menu(r"^Enter manually\.\.\.$", prompt="Docker image", title="Enter the application image")
        ui.text(r"Docker image: ", ctx.image, title="Use nginx alpine")
        ui.menu(r"^80$", prompt="Container port", first_match=True, title="Set container port 80")
        ui.menu(r"^Use default: 80$", prompt="Listen port", title="Expose HTTP port 80")
        ui.menu(r"^Disabled$", prompt="WebSocket", title="Leave WebSocket disabled")
        ui.menu(r"^Expose now$", prompt="Expose port now", title="Expose the application now")
        ui.text(r"Additional docker run options \(optional; finish with empty line\): ", "", title="Keep Docker options empty")
        ui.menu(r"^Run$", prompt="Review command", require=["example.com", "nginx:alpine"], title="Review the HTTP backend")
        ui.finish(title="Backend created")
    ctx.request("default-deny", 403)
    with ctx.ui("public-demo-access", command="set-backend-acl-policy") as ui:
        ui.start(r"^Advanced command browser$")
        ui.menu(r"^Backend Access Overrides$", prompt="Select a category", title="Open backend access settings")
        ui.menu(r"^Set Backend ACL Policy(?:\s|$)", title="Set the domain ACL policy")
        ui.menu(r"^example.com$", prompt="domain", title="Select example.com")
        ui.menu(r"^allow(?:\s|$)", prompt="Policy", title="Allow this public demo")
        ui.menu(r"^Run$", prompt="Review command", title="Review the public demo policy")
        ui.finish(title="Public demo policy applied")
    assert "Welcome to nginx" in ctx.request("http-allowed"), "HTTP returned an unexpected body"
    ctx.terminal_command("verify-http", ["curl", "--noproxy", "*", "-sS", "-D", "-", "-o", "/dev/null",
                         "http://127.0.0.1", "-H", "Host: example.com"],
                         require=["HTTP/1.1 200"], title="HTTP responds successfully")
    ctx.check_config("check-http")

    with ctx.ui("https-port", command="add-port") as ui:
        ui.start(r"^Expose or update a port$", r"^Add Port(?:\s|$)")
        ui.menu(r"^example.com$", title="Select the existing application")
        ui.menu(r"^443$", prompt="Listen port", title="Expose HTTPS port 443")
        ui.menu(r"^80$", prompt="Backend container port", title="Keep backend port 80")
        ui.menu(r"^HTTPS(?:\s|$)", prompt="Protocol", title="Choose HTTPS")
        ui.menu(r"^Generate self-signed certificate(?:\s|$)", prompt="Certificate", title="Generate a local certificate")
        ui.menu(r"^no(?:\s|$)", prompt="WebSocket", enter=True, title="Keep WebSocket off")
        ui.menu(r"^Off(?:\s|$)", prompt="HTTP/3", enter=True, title="Keep HTTP3 off")
        ui.menu(r"^Auto(?:\s|$)", prompt="Alt-Svc", enter=True, title="Keep automatic Alt-Svc")
        ui.menu(r"^Run$", prompt="Review command", require=["HTTP/3: off", "Alt-Svc: auto"], title="Review HTTPS configuration")
        ui.finish(title="HTTPS listener created")
    assert "Welcome to nginx" in ctx.request("https-allowed", https=True), "HTTPS returned an unexpected body"
    ctx.terminal_command("verify-https", ["curl", "--noproxy", "*", "-ksS", "-D", "-", "-o", "/dev/null",
                         "--resolve", "example.com:443:127.0.0.1", "https://example.com/"],
                         require=[r"HTTP/(?:1.1|2) 200"], title="Local HTTPS responds successfully")
    ctx.check_config("check-https")
    owner = ctx.tool / "state/domains" / ctx.domain
    ports = list(csv.DictReader((owner / "config/ports.csv").open()))
    https = next(row for row in ports if row["listen_port"] == "443")
    certificate = ctx.tool / "state/domains" / https["certificate_owner"] / "certs" / https["certificate_id"] / "fullchain.pem"
    expected = ctx.run(["openssl", "x509", "-in", certificate, "-noout", "-fingerprint", "-sha256"], label="owned-certificate").strip()
    served = ctx.run(["openssl", "s_client", "-connect", "127.0.0.1:443", "-servername", ctx.domain],
                     label="served-certificate", input="", retain_output=False)
    pem = re.search(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", served, re.S)
    assert pem, "The HTTPS listener did not present a certificate"
    actual = ctx.run(["openssl", "x509", "-noout", "-fingerprint", "-sha256"], label="served-fingerprint", input=pem.group()).strip()
    assert expected == actual, "The served and owned certificate fingerprints differ"
    ctx.proof("served-certificate-matches", fingerprint=actual)

    with ctx.ui("block-request", command="add-security-rule") as ui:
        ui.start(r"^Access control & security rules$", r"^Add Security Rule(?:\s|$)")
        ui.menu(r"^example.com$", prompt="Select domain", title="Select the application")
        ui.menu(r"^Block when conditions match", prompt="Action", title="Block matching requests")
        ui.text(r"Number of conditions[^\r\n]*: ", "1", title="Use one condition")
        ui.text(r"Status code override[^\r\n]*: ", "403", title="Return HTTP 403")
        ui.menu(r"^Header", prompt="Condition 1 source", title="Inspect a request header")
        ui.text(r"Header name: ", "User-Agent", title="Inspect User-Agent")
        ui.menu(r"^Contains(?:\s|$)", prompt="Condition 1 operator", title="Match a contained value")
        ui.text(r"Value for header contains: ", "BadBot", title="Match BadBot")
        ui.menu(r"^Confirm$", prompt="Create security rule", require=["example.com", "block", "BadBot", "403"], title="Confirm the complete security rule")
        ui.finish(title="Block rule applied")
    ctx.request("ordinary-http")
    ctx.request("blocked-http", 403, agent="BadBot")
    ctx.request("blocked-https", 403, https=True, agent="BadBot")
    ctx.terminal_command("verify-block", ["curl", "--noproxy", "*", "-sS", "-D", "-", "-o", "/dev/null",
                         "http://127.0.0.1", "-H", "Host: example.com", "-A", "BadBot"],
                         require=["HTTP/1.1 403"], title="The matching request is blocked")
    with ctx.ui("list-security-rule", command="list-security-rules") as ui:
        ui.start(r"^Access control & security rules$", r"^List Security Rules(?:\s|$)")
        ui.menu(r"^example.com$", title="List this domain rules")
        listing = ui.finish(require=["action=block", "User-Agent", "BadBot"], title="Find the rule global ID")
    ids = re.findall(r"^([0-9]+):[^\r\n]*example\.com", listing, re.M)
    assert len(ids) == 1, "Expected one directly owned demo rule"
    with ctx.ui("disable-rule", command="disable-security-rule") as ui:
        ui.start(r"^Access control & security rules$", r"^Disable Security Rule(?:\s|$)")
        ui.menu(r"example\.com", prompt="id|rule", title="Select the demonstrated rule")
        ui.menu(r"^Run$", prompt="Review command", require=[ids[0]], title="Review disabling the rule")
        ui.finish(title="Rule disabled")
    ctx.request("disabled-http", agent="BadBot")
    ctx.request("disabled-https", https=True, agent="BadBot")

    applied = owner / "runtime/applied/headers.csv"
    draft = owner / "config/headers.csv"
    before_applied = applied.read_bytes()
    with draft.open("w", newline="") as stream:
        writer = csv.writer(stream, lineterminator="\n")
        writer.writerow(["header_type", "header_name", "header_value"])
        writer.writerow(["response", "X-Interactive-Draft", "activated"])
    draft_hash = hashlib.sha256(draft.read_bytes()).hexdigest()
    ctx.proof("manual-draft-created", draft_sha256=draft_hash)
    ctx.terminal_command("inspect-draft-file", ["cat", "state/domains/example.com/config/headers.csv"],
                         require=["X-Interactive-Draft,activated"], title="The edited draft contains a new header")
    ctx.request("draft-inactive", header=False)
    response = ctx.terminal_command("verify-draft-inactive", ["curl", "--noproxy", "*", "-sS", "-D", "-", "-o", "/dev/null",
                                    "--resolve", "example.com:80:127.0.0.1", "http://example.com/"],
                                    require=["HTTP/1.1 200"], title="The draft header is not active yet")
    assert "x-interactive-draft:" not in response.lower(), "An unapplied header appeared in the visible response"
    before = ctx.runtime_snapshot()
    domain_action(ctx, "validate-draft", "validate-domain-config")
    domain_action(ctx, "preview-draft", "apply-domain-config", r"^Review changes without applying them(?: \(current\))?$")
    assert ctx.runtime_snapshot() == before, "Preview changed runtime"
    assert applied.read_bytes() == before_applied, "Preview changed applied configuration"
    ctx.request("preview-inactive", header=False)
    with ctx.ui("pending-edit-cancel", command="stop-backend") as ui:
        ui.start(r"^Start / stop services$", r"^Stop Backend(?:\s|$)")
        ui.menu(r"^example.com$", title="Select the edited domain")
        ui.menu(r"^Cancel command$", prompt="Unapplied file changes", title="Preserve the pending draft")
        ui.menu(r"^Back$", prompt="Start / stop services", title="Return without stopping")
        ui.quit()
    assert hashlib.sha256(draft.read_bytes()).hexdigest() == draft_hash, "Cancel overwrote the pending draft"
    assert ctx.runtime_snapshot() == before, "Cancel changed runtime"
    domain_action(ctx, "apply-draft", "apply-domain-config", r"^Apply changes$")
    ctx.request("draft-active-http", header=True)
    ctx.request("draft-active-https", https=True, header=True)
    ctx.terminal_command("verify-draft-active", ["curl", "--noproxy", "*", "-sS", "-D", "-", "-o", "/dev/null",
                         "--resolve", "example.com:80:127.0.0.1", "http://example.com/"],
                         require=["HTTP/1.1 200", "X-Interactive-Draft: activated"],
                         title="The applied header appears in a real response")
    ctx.check_config("check-draft")
    ctx.proof("draft-preview-apply-and-cancel", draft_sha256=draft_hash)
