"""Real interactive captures for headers, access policy, certificates and mTLS.

Run only in the disposable capture VM. Setup uses Dockistrate; generated client
keys remain in the isolated state tree and must never enter the published assets.
"""

import os
import ipaddress
import re
import shutil


def _request(ctx, label, expected=200, **options):
    result = ctx.request(label, expected, **options)
    header = options.get("header")
    if isinstance(header, str):
        actual = (ctx.evidence / (ctx.slug(label) + ".headers")).read_text().lower()
        if header.lower() not in actual:
            raise AssertionError(f"{label}: expected response header {header!r}, got {actual!r}")
        ctx.proof(label + "-header", header=header)
    return result


def _m(choice):
    return ("menu", choice)


def _t(prompt, value):
    return ("text", prompt, str(value))


def _host(ctx):
    return _m(r"^" + re.escape(ctx.domain) + r"(?:\s|$)")


def _execute(ctx, command, steps=(), *, journey=None, require=(), cancel=False,
             after=(), readonly=False):
    with ctx.ui(journey or command) as ui:
        ui.command(command)
        for step in steps:
            if step[0] == "menu":
                ui.menu(step[1])
            else:
                ui.text(step[1], step[2])
        if not readonly:
            ui.menu(r"^Cancel$" if cancel else r"^Run$", prompt="Review command",
                    require=(re.escape(command),))
            if cancel:
                ui.menu(r"^Back$", prompt="Search all commands", title="Return without running")
                ui.quit()
                return
            if command.startswith(("remove-", "revoke-")):
                ui.text(r"Type YES to run this destructive command: ", "YES")
        for prompt, value in after:
            ui.text(prompt, value, secret="password" in prompt.lower())
        return ui.finish(require=require)


def headers(ctx):
    host = _host(ctx)
    name_prompt = r"Example: X-Forwarded-Proto[^\r\n]*: "
    value_prompt = r"Blank: leave blank only when an empty value is intentional[^\r\n]*: "
    for backend, name in ((True, "X-Guide"), (False, "X-Global-Guide")):
        prefix = "backend-" if backend else ""
        before = [host] if backend else []
        command = f"add-{prefix}header"
        _execute(ctx, command, before + [_m(r"^response(?:\s|$)"),
                 _t(name_prompt, name), _t(value_prompt, "preview")],
                 journey="headers" if backend else command)
        _request(ctx, command + "-response", header=name + ": preview")
        if backend:
            ctx.terminal_command("headers-verified", ["curl", "--noproxy", "*", "-sS", "-D", "-", "-o", "/dev/null",
                                 "http://127.0.0.1", "-H", "Host: " + ctx.domain],
                                 require=(r"X-Guide: preview",), title="Read the new response header")
        _execute(ctx, f"list-{prefix}headers", before, readonly=True,
                 require=(name, "preview"))
        _execute(ctx, f"update-{prefix}header", before + [_m(r"^response(?:\s|$)"),
                 _m("^" + name + r"(?:\s|$)"), _t(value_prompt, "reviewed")])
        _request(ctx, f"update-{prefix}header-response", header=name + ": reviewed")
        _execute(ctx, f"remove-{prefix}header", before + [_m(r"^response(?:\s|$)"),
                 _m("^" + name + r"(?:\s|$)")])
        if backend:
            # With zero backend header rows, the picker offers no-state guidance.
            # This explicitly labelled CLI inspection verifies removal instead.
            ctx.terminal_command("headers-backend-removed",
                                 [ctx.tool / "dockistrate.sh", "list-backend-headers", ctx.domain],
                                 title="Inspect headers after removal")
        else:
            _execute(ctx, "list-headers", readonly=True, journey="headers-global-removed")

    for command, prompt, value, args in (
        ("set-hsts", r"HSTS value[^\r\n]*: ", "max-age=300", []),
        ("set-csp", r"CSP value[^\r\n]*: ", "default-src 'self'", []),
        ("set-backend-hsts", r"HSTS for [^\r\n]*: ", "max-age=600", [host]),
        ("set-backend-csp", r"CSP for [^\r\n]*: ", "default-src 'none'", [host]),
    ):
        _execute(ctx, command, args + [_t(prompt, value)])
    _request(ctx, "browser-policy-headers", https=True, header="Strict-Transport-Security: max-age=600")
    _execute(ctx, "remove-all-backend-headers", [host], cancel=True,
             journey="headers-bulk-cancel")
    _execute(ctx, "remove-all-backend-headers", [host])
    _execute(ctx, "remove-all-headers")
    _execute(ctx, "control-server-tokens", [_m(r"^off(?:\s|$)")])
    _execute(ctx, "show-server-tokens", readonly=True, require=("off",))
    _request(ctx, "server-token-response")
    ctx.check_config("headers-config")


def client_ip(ctx):
    host = _host(ctx)
    prompt = r"Example: X-Forwarded-For or off[^\r\n]*: "
    for command, value, args in (
        ("set-client-ip-header", "X-Forwarded-For", []),
        ("set-proxy-ip-header", "Proxy-IP", []),
        ("set-backend-client-ip-header", "X-Real-IP", [host]),
        ("set-backend-proxy-ip-header", "Backend-Proxy-IP", [host]),
    ):
        _execute(ctx, command, args + [_t(prompt, value)],
                 journey="client-ip" if command == "set-backend-client-ip-header" else command)
    # This documentation-only address is not asserted to be a live proxy.
    _execute(ctx, "set-trusted-proxies", [_t(r"ranges[^\r\n]*: ", "198.51.100.10/32")])
    _execute(ctx, "set-real-ip-recursive", [_m(r"^on(?:\s|$)")])
    ctx.check_config("client-ip-config")
    # Temporary response headers expose the actual addresses Nginx resolved;
    # they make trust behavior observable without requiring a separate app.
    ctx.cli("observe-resolved-client", "add-backend-header", ctx.domain,
            "response", "X-Observed-Client", "$remote_addr")
    ctx.cli("observe-original-peer", "add-backend-header", ctx.domain,
            "response", "X-Observed-Peer", "$realip_remote_addr")
    _request(ctx, "untrusted-forwarding-header", extra=("-H", "X-Real-IP: 203.0.113.8"))
    observed = (ctx.evidence / "untrusted-forwarding-header.headers").read_text()
    peer = re.search(r"^X-Observed-Peer:\s*([^\r\n]+)", observed, re.I | re.M)
    client = re.search(r"^X-Observed-Client:\s*([^\r\n]+)", observed, re.I | re.M)
    if not peer or not client or peer.group(1).strip() != client.group(1).strip():
        raise AssertionError("An untrusted forwarding header changed the resolved client:\n" + observed)
    peer_ip = str(ipaddress.IPv4Address(peer.group(1).strip()))
    if peer_ip == "203.0.113.8":
        raise AssertionError("Untrusted peer was accepted as the spoofed documentation address")
    ctx.proof("untrusted-client-address-preserved", peer=peer_ip, resolved_client=peer_ip)
    # The local request sender now deliberately acts as a trusted forwarding
    # proxy in this disposable VM. Its actual observed peer address is used.
    _execute(ctx, "set-trusted-proxies", [_t(r"ranges[^\r\n]*: ", peer_ip + "/32")],
             journey="client-ip-trusted-peer")
    _request(ctx, "trusted-forwarding-header", extra=("-H", "X-Real-IP: 203.0.113.8"),
             header="X-Observed-Client: 203.0.113.8")
    trusted = (ctx.evidence / "trusted-forwarding-header.headers").read_text()
    if not re.search(r"^X-Observed-Peer:\s*" + re.escape(peer_ip) + r"\s*$", trusted, re.I | re.M):
        raise AssertionError("Trusted resolution lost the original peer:\n" + trusted)
    ctx.terminal_command("verify-client-ip", ["curl", "--noproxy", "*", "-sS", "-D", "-", "-o", "/dev/null",
                         "http://127.0.0.1", "-H", "Host: " + ctx.domain, "-H", "X-Real-IP: 203.0.113.8"],
                         require=(r"X-Observed-Client: 203\.0\.113\.8", r"X-Observed-Peer: " + re.escape(peer_ip)),
                         title="Trusted header changes the client while retaining the peer")
    _execute(ctx, "remove-backend-client-ip-header", [host])
    _execute(ctx, "remove-backend-proxy-ip-header", [host])
    _execute(ctx, "set-trusted-proxies", [_t(r"ranges[^\r\n]*: ", "none")],
             journey="trusted-proxies-reset")
    _execute(ctx, "set-real-ip-recursive", [_m(r"^off(?:\s|$)")],
             journey="real-ip-recursive-reset")
    for header in ("X-Observed-Client", "X-Observed-Peer"):
        ctx.cli("remove-observation-" + header.lower(), "remove-backend-header", ctx.domain, "response", header)


def access_defaults(ctx):
    host = _host(ctx)
    for command, args in (
        ("set-acl-policy", [_m(r"^deny(?:\s|$)")]),
        ("set-acl-status", [_t(r"Example: 301[^\r\n]*: ", "403")]),
        ("set-security-rule-status", [_t(r"Example: 301[^\r\n]*: ", "403")]),
        ("set-backend-acl-status", [host, _t(r"Example: 301[^\r\n]*: ", "403")]),
        ("set-backend-security-rule-status", [host, _t(r"Example: 301[^\r\n]*: ", "404")]),
        ("set-backend-acl-policy", [host, _m(r"^allow(?:\s|$)")]),
    ):
        _execute(ctx, command, args,
                 journey="access-defaults" if command == "set-backend-acl-policy" else command)
    _request(ctx, "access-override-allow")
    for command in ("remove-backend-acl-status", "remove-backend-security-rule-status",
                    "remove-backend-acl-policy"):
        _execute(ctx, command, [host])
    _request(ctx, "access-inherited-deny", expected=403)
    ctx.cli("restore-demo-allow", "set-backend-acl-policy", ctx.domain, "allow")


def acl_rules(ctx):
    host = _host(ctx)
    _execute(ctx, "add-acl", [host, _m(r"^Apply to L7 and L3"), _m(r"^allow$"),
             _t(r"ip_list[^\r\n]*: ", "203.0.113.8")], journey="acl-rules")
    _execute(ctx, "list-acl", readonly=True, require=("203.0.113.8",))
    with ctx.ui("update-acl") as ui:
        ui.command("update-acl")
        ui.menu(r"203\.0\.113\.8", prompt="Select ACL rule")
        ui.menu(r"^Keep current:", prompt="Domain")
        ui.menu(r"^Layer 7", prompt="Scope")
        ui.menu(r"^Deny$", prompt="Action")
        ui.text(r"IP or CIDR [^\r\n]*: ", "203.0.113.0/24")
        ui.text(r"Status code [^\r\n]*: ", "403")
        ui.menu(r"^Run$", prompt="Review command")
        ui.finish()
    for command in ("disable-acl", "enable-acl"):
        _execute(ctx, command, [_m(r"203\.0\.113\.0/24")])
    _execute(ctx, "add-acl", [host, _m(r"^Layer 7"), _m(r"^allow$"),
             _t(r"ip_list[^\r\n]*: ", "198.51.100.10")], journey="acl-second-rule")
    _execute(ctx, "move-acl-rule", [_t(r"From position[^\r\n]*: ", "2"),
                                     _t(r"To position[^\r\n]*: ", "1")])
    for command in ("disable-all-acl", "enable-all-acl"):
        _execute(ctx, command)
    _execute(ctx, "remove-acl", [_m(r"198\.51\.100\.10")])
    _execute(ctx, "remove-all-acl", cancel=True, journey="acl-remove-all-cancel")
    _execute(ctx, "remove-all-acl")
    _execute(ctx, "list-acl", readonly=True, journey="acl-cleanup-result")
    ctx.check_config("acl-config")
    _request(ctx, "acl-demo-baseline")


def _add_rule(ctx, journey, action, count=1):
    with ctx.ui(journey) as ui:
        ui.command("add-security-rule")
        ui.menu(r"^" + re.escape(ctx.domain) + r"(?:\s|$)")
        ui.menu({"block": r"^Block when", "allow": r"^Allow past", "require": r"^Require conditions"}[action])
        ui.text(r"Number of conditions[^\r\n]*: ", str(count))
        if count > 1:
            ui.menu(r"^and$", prompt="Condition mode")
        if action != "allow":
            ui.text(r"Status code override[^\r\n]*: ", "403")
        ui.menu(r"^Header", prompt="Condition 1 source")
        ui.text(r"Header name: ", "User-Agent" if action == "block" else "X-Guide")
        ui.menu(r"^Contains" if action == "block" else r"^Equals", prompt="Condition 1 operator")
        ui.text(r"Value for header [^\r\n]*: ", "BadBot" if action == "block" else "trusted")
        if count > 1:
            ui.menu(r"^Method", prompt="Condition 2 source")
            ui.menu(r"^Equals", prompt="Condition 2 operator")
            ui.text(r"Value for method [^\r\n]*: ", "GET")
        ui.menu(r"^Confirm$", prompt="Security rule summary")
        ui.finish()


def security_rules(ctx):
    _add_rule(ctx, "security-rules", "block", count=2)
    _request(ctx, "security-baseline")
    _request(ctx, "security-block", expected=403, agent="BadBot")
    ctx.terminal_command("security-block-verified", ["curl", "--noproxy", "*", "-sS", "-D", "-", "-o", "/dev/null",
                         "http://127.0.0.1", "-H", "Host: " + ctx.domain, "-A", "BadBot"],
                         require=(r"HTTP/1\.1 403",), title="Verify the matching request is blocked")
    _execute(ctx, "set-security-rule-mode", [_m(re.escape(ctx.domain)), _m(r"^or(?:\s|$)")])
    # OR now matches GET independently of the user agent.
    _request(ctx, "security-mode-or", expected=403)
    _execute(ctx, "set-security-rule-mode", [_m(re.escape(ctx.domain)), _m(r"^and(?:\s|$)")],
             journey="security-mode-reset")
    _execute(ctx, "duplicate-security-rule", [_t(r"Example: 1[^\r\n]*: ", "1")])
    _execute(ctx, "move-security-rule", [_t(r"From position[^\r\n]*: ", "2"),
                                         _t(r"To position[^\r\n]*: ", "1")])
    with ctx.ui("update-security-rule") as ui:
        ui.command("update-security-rule")
        ui.menu(re.escape(ctx.domain), first_match=True)
        ui.text(r"Domain [^\r\n]*: ", ctx.domain)
        ui.menu(r"^Block when")
        ui.text(r"Status code override[^\r\n]*: ", "404")
        ui.menu(r"^Keep current$", prompt="Replace conditions")
        ui.menu(r"^Run$", prompt="Review command", require=(r"Status code: 404",))
        ui.finish()
    _request(ctx, "security-updated-status", expected=404, agent="BadBot")
    for command in ("disable-security-rule", "enable-security-rule", "remove-security-rule"):
        with ctx.ui(command) as ui:
            ui.command(command)
            ui.menu(re.escape(ctx.domain), first_match=True)
            ui.menu(r"^Run$", prompt="Review command")
            if command.startswith("remove-"):
                ui.text(r"Type YES to run this destructive command: ", "YES")
            ui.finish()
    _execute(ctx, "disable-all-security-rules")
    _request(ctx, "security-disabled", agent="BadBot")
    _execute(ctx, "enable-all-security-rules")
    _request(ctx, "security-enabled", expected=403, agent="BadBot")
    _execute(ctx, "list-security-rules", [_host(ctx)], readonly=True)
    _execute(ctx, "remove-all-security-rules", cancel=True, journey="security-bulk-cancel")
    _execute(ctx, "remove-all-security-rules")
    _add_rule(ctx, "security-require", "require")
    _request(ctx, "require-missing", expected=403)
    _request(ctx, "require-present", extra=("-H", "X-Guide: trusted"))
    ctx.cli("remove-require-fixture", "remove-all-security-rules")
    _add_rule(ctx, "security-allow", "allow")
    _add_rule(ctx, "security-block-after-allow", "block")
    _request(ctx, "allow-exception", agent="BadBot", extra=("-H", "X-Guide: trusted"))
    _request(ctx, "allow-does-not-open-nonmatch", expected=403, agent="BadBot")
    ctx.cli("remove-rule-fixtures", "remove-all-security-rules")
    ctx.check_config("security-rules-config")


def _verify_http3(ctx):
    # Debian 13's official curl package supports HTTP/3:
    # https://www.debian.org/releases/trixie/release-notes.en.pdf (section 2.2.8)
    # https://curl.se/docs/manpage.html#--http3-only
    # Dockistrate has no general-purpose client-container runner. Direct Docker
    # here runs an ephemeral verification client, not a backend/proxy mutation.
    base = "debian:trixie-slim"
    ctx.run(["docker", "pull", base], label="http3-client-base-pull", timeout=300)
    base_digest = ctx.run(["docker", "image", "inspect", "--format", "{{index .RepoDigests 0}}", base],
                          label="http3-client-base-digest").strip()
    if not re.fullmatch(r"[^\s]+@sha256:[0-9a-f]{64}", base_digest):
        raise AssertionError("Cannot record the HTTP/3 client base digest: " + base_digest)
    dockerfile = (f"FROM {base_digest}\n"
                  "RUN apt-get update && apt-get install --no-install-recommends -y curl ca-certificates "
                  "&& rm -rf /var/lib/apt/lists/*\n"
                  'ENTRYPOINT ["curl"]\n')
    ctx.run(["docker", "build", "--tag", "dockistrate-docs-curl-http3", "-"],
            input=dockerfile, label="http3-client-install-official-package", timeout=600)
    image_id = ctx.run(["docker", "image", "inspect", "--format", "{{.Id}}", "dockistrate-docs-curl-http3"],
                       label="http3-client-image-id").strip()
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
        raise AssertionError("Cannot record the installed HTTP/3 client image: " + image_id)
    version = ctx.run(["docker", "run", "--rm", image_id, "--version"], label="http3-client-version")
    if not re.search(r"^Features:.*\bHTTP3\b", version, re.M):
        raise AssertionError("Official curl client image does not advertise HTTP3 support:\n" + version)
    ca = ctx.tool / "state/domains" / ctx.domain / "certs/selfsigned-443/fullchain.pem"
    command = ["docker", "run", "--rm", "--network", "host", "--user", "0",
               "--mount", f"type=bind,src={ca},dst=/tmp/server-ca.pem,readonly", image_id,
               "--noproxy", "*", "--http3-only", "--fail", "--silent", "--show-error",
               "--connect-timeout", "10", "--max-time", "30", "--cacert", "/tmp/server-ca.pem",
               "--resolve", ctx.domain + ":443:127.0.0.1", "--dump-header", "-", "--output", "/dev/null",
               "--write-out", "\nHTTP version: %{http_version}; status: %{http_code}\n",
               "https://" + ctx.domain + "/"]
    ctx.terminal_command("http3-verified", command,
                         require=(r"HTTP/3 200", r"HTTP version: 3; status: 200"),
                         title="HTTP/3 request succeeds without fallback", timeout=90)
    ctx.proof("http3-transport", client_image_id=image_id, base_digest=base_digest,
              protocol="HTTP/3", http_status=200,
              server_trust="owned self-signed server certificate")


def tls_settings(ctx):
    protocol_prompt = r"Example: TLSv1\.2 TLSv1\.3[^\r\n]*: "
    cipher_prompt = r"Example: ECDHE\+AESGCM:ECDHE\+CHACHA20[^\r\n]*: "
    for command, args in (
        ("set-tls-protocols", [_t(protocol_prompt, "TLSv1.2 TLSv1.3")]),
        ("set-tls-ciphers", [_t(cipher_prompt, "HIGH:!aNULL:!MD5")]),
        ("set-port-tls-protocols", [_m(r"^443(?:\s|$)"), _t(protocol_prompt, "TLSv1.3")]),
        ("set-port-tls-ciphers", [_m(r"^443(?:\s|$)"), _t(cipher_prompt, "HIGH:!aNULL:!MD5")]),
    ):
        _execute(ctx, command, args,
                 journey="tls-settings" if command == "set-port-tls-protocols" else command)
    _request(ctx, "tls13-response", https=True, extra=("--tlsv1.3",))
    server_ca = ctx.tool / "state/domains" / ctx.domain / "certs/selfsigned-443/fullchain.pem"
    ctx.terminal_command("tls12-excluded", ["curl", "--noproxy", "*", "--tlsv1.2", "--tls-max", "1.2",
                         "--silent", "--show-error", "--max-time", "15", "--cacert", str(server_ca),
                         "--resolve", ctx.domain + ":443:127.0.0.1", "https://" + ctx.domain + "/"],
                         expected_exit=35, require=(r"curl: \(35\)",),
                         title="TLS 1.2 is rejected while the listener requires TLS 1.3")
    for command in ("remove-port-tls-protocols", "remove-port-tls-ciphers"):
        _execute(ctx, command, [_m(r"^443(?:\s|$)")])
    _request(ctx, "tls12-restored", https=True, extra=("--tlsv1.2", "--tls-max", "1.2"))
    _execute(ctx, "set-port-http3", [_m(r"^443(?:\s|$)"), _m(r"^On(?:\s|$)"), _m(r"^Auto(?:\s|$)")],
             journey="http3")
    _execute(ctx, "list-port-http3", [_m(r"^443(?:\s|$)")], readonly=True)
    _request(ctx, "http3-advertisement", https=True, header="alt-svc:")
    _verify_http3(ctx)
    _execute(ctx, "set-port-http3", [_m(r"^443(?:\s|$)"), _m(r"^Off(?:\s|$)"), _m(r"^Auto(?:\s|$)")],
             journey="http3-disable")
    ctx.check_config("tls-settings-config")


def certificates(ctx):
    host = _host(ctx)
    _execute(ctx, "add-cert", [host, _m(r"^Enter manually"),
             _t(r"Certificate port suffix[^\r\n]*: ", "8443"),
             _m(r"^Generate self-signed")], journey="certificates",
             after=((r"Redirect HTTP port [^\r\n]*: ", "yes"),
                    (r"Redirect target port [^\r\n]*: ", "8443")))
    _request(ctx, "certificate-created-redirect", expected=301, header="Location: https://example.com:8443/")
    ctx.cli("restore-http-for-provider-comparison", "set-port-redirect", ctx.domain, "80", "off")
    _execute(ctx, "list-certs", readonly=True, require=("8443",))
    _execute(ctx, "replace-cert", [host, _m(r"^8443(?:\s|$)"),
                                   _m(r"^Generate self-signed")])
    ctx.terminal_command("certificate-local-trust", ["curl", "--noproxy", "*", "--fail", "-sS", "-D", "-", "-o", "/dev/null",
             "--resolve", ctx.domain + ":8443:127.0.0.1", "--cacert",
             str(ctx.tool / "state/domains" / ctx.domain / "certs/selfsigned-8443/fullchain.pem"),
             "https://" + ctx.domain + ":8443/"], require=(r"HTTP/(?:1\.1|2) 200",), title="Trust the owned certificate and request HTTPS")
    # Show genuine external-provider prompts, cancel before invoking ACME.
    _execute(ctx, "add-cert", [host, _m(r"^Enter manually"),
             _t(r"Certificate port suffix[^\r\n]*: ", "9443"),
             _m(r"^Generate Let's Encrypt")], journey="certificate-acme-prerequisites", cancel=True)
    _execute(ctx, "renew-certs", cancel=True, journey="certificate-renewal-review")
    _execute(ctx, "renew-certs", journey="certificate-renewal-scan",
             require=("Scanning configured HTTPS certificates", "no certificates required renewal"))
    source = ctx.tool / "state/domains" / ctx.domain / "certs/selfsigned-443"
    _execute(ctx, "add-cert", [host, _m(r"^Enter manually"),
             _t(r"Certificate port suffix[^\r\n]*: ", "9443"),
             _m(r"^Upload existing"),
             _t(r"Example: /path/to/fullchain\.pem[^\r\n]*: ", str(source / "fullchain.pem")),
             _t(r"Example: /path/to/privkey\.pem[^\r\n]*: ", str(source / "privkey.pem"))],
             journey="certificate-upload",
             after=((r"Redirect HTTP port [^\r\n]*: ", "no"),))
    ctx.terminal_command("uploaded-certificate-local-trust", ["curl", "--noproxy", "*", "--fail", "-sS", "-D", "-", "-o", "/dev/null",
             "--resolve", ctx.domain + ":9443:127.0.0.1", "--cacert", str(source / "fullchain.pem"),
             "https://" + ctx.domain + ":9443/"], require=(r"HTTP/(?:1\.1|2) 200",), title="Verify the uploaded certificate serves HTTPS")
    ctx.cli("remove-upload-demo-listener", "remove-port", ctx.domain, "9443")
    _execute(ctx, "remove-cert", [host, _m(r"^9443(?:\s|$)")], journey="remove-uploaded-certificate")
    ctx.cli("remove-demo-https-listener", "remove-port", ctx.domain, "8443")
    _execute(ctx, "remove-cert", [host, _m(r"^8443(?:\s|$)")])
    ctx.check_config("certificate-cleanup-config")


def mtls(ctx):
    host = _host(ctx)
    client_prompt = r"Client name[^\r\n]*: "
    material = ctx.tool / "state/domains" / ctx.domain / "mtls"
    _execute(ctx, "enable-backend-mtls", [host, _t(client_prompt, "guide-client")],
             journey="mtls-clients")
    _execute(ctx, "list-backend-client-certs", [host], readonly=True, require=("guide-client",))
    _execute(ctx, "list-backend-cas", readonly=True, require=(re.escape(ctx.domain),))
    _request(ctx, "mtls-no-client", https=True, expected=400)
    credentials = ("--cert", str(material / "guide-client.crt"),
                   "--key", str(material / "guide-client.key"))
    _request(ctx, "mtls-valid-client", https=True, extra=credentials)
    server_ca = ctx.tool / "state/domains" / ctx.domain / "certs/selfsigned-443/fullchain.pem"
    ctx.terminal_command("mtls-verified", ["curl", "--noproxy", "*", "--fail", "-sS", "-D", "-", "-o", "/dev/null",
                         "--resolve", ctx.domain + ":443:127.0.0.1", "--cacert", str(server_ca),
                         *credentials, "https://" + ctx.domain + "/"],
                         require=(r"HTTP/(?:1\.1|2) 200",), title="Authenticate with the issued client certificate")
    _execute(ctx, "export-backend-client-p12", [host, _m(r"^guide-client$")],
             journey="mtls-export", after=((r"Enter export password: ", "disposable-docs-password"),
                                            (r"Confirm export password: ", "disposable-docs-password")),
             require=(r"guide-client\.p12",))
    ctx.terminal_command("pkcs12-inspection", ["openssl", "pkcs12", "-info", "-noout", "-in", str(material / "guide-client.p12"),
                         "-passin", "pass:disposable-docs-password"], require=("MAC:",),
                         title="Inspect the protected bundle without displaying keys")
    # Retain the old client only under runtime tmp, never the exported evidence.
    old = ctx.tool / "state/tmp/documentation-old-client"
    old.mkdir(parents=True, exist_ok=True)
    for suffix in ("crt", "key"):
        shutil.copyfile(material / ("guide-client." + suffix), old / ("old." + suffix))
        (old / ("old." + suffix)).chmod(0o600)
    _execute(ctx, "replace-backend-client-cert", [host, _m(r"^guide-client$")],
             journey="mtls-rotation")
    _request(ctx, "mtls-replacement-client", https=True, extra=credentials)
    _request(ctx, "mtls-old-client-rejected", https=True, expected=400,
                extra=("--cert", str(old / "old.crt"), "--key", str(old / "old.key")))
    _execute(ctx, "add-backend-client-cert", [host, _t(client_prompt, "second-client")])
    _execute(ctx, "revoke-backend-client-cert", [host, _t(client_prompt, "second-client")])
    _request(ctx, "mtls-revoked-client", https=True, expected=400,
                extra=("--cert", str(material / "second-client.crt"),
                       "--key", str(material / "second-client.key")))
    _execute(ctx, "remove-backend-client-cert", [host, _m(r"^second-client$")])
    # Save a currently valid client so CA rotation is checked independently of
    # the earlier client-revocation check. These bytes never leave runtime tmp.
    for suffix in ("crt", "key"):
        shutil.copyfile(material / ("guide-client." + suffix), old / ("prior-ca." + suffix))
        (old / ("prior-ca." + suffix)).chmod(0o600)
    _execute(ctx, "replace-backend-ca", [host], cancel=True, journey="mtls-authority-review")
    _execute(ctx, "replace-backend-ca", [host], journey="mtls-authority")
    _request(ctx, "mtls-prior-authority-rejected", https=True, expected=400,
                extra=("--cert", str(old / "prior-ca.crt"), "--key", str(old / "prior-ca.key")))
    if not (material / "guide-client.p12").is_file():
        raise AssertionError("CA rotation unexpectedly removed the previously exported bundle")
    ctx.proof("mtls-export-retained-after-ca-rotation")
    _execute(ctx, "add-backend-client-cert", [host, _t(client_prompt, "replacement-client")],
             journey="mtls-new-authority-client")
    _request(ctx, "mtls-new-authority", https=True,
                extra=("--cert", str(material / "replacement-client.crt"),
                       "--key", str(material / "replacement-client.key")))
    _execute(ctx, "disable-backend-mtls", [host])
    _request(ctx, "mtls-disabled", https=True)
    _execute(ctx, "enable-backend-mtls", [host, _t(client_prompt, "")], journey="mtls-reenable")
    _execute(ctx, "remove-backend-ca", [host])
    _request(ctx, "mtls-authority-removed", https=True)
    if material.exists():
        raise AssertionError("Authority removal left the owned mTLS directory behind")
    ctx.proof("mtls-owned-material-removed")
    ctx.check_config("mtls-config")
    shutil.rmtree(old)


def _mark_repeated_setup(ctx, first_frame):
    """Retain original evidence while keeping repeated setup out of galleries."""
    for frame in ctx.frames[first_frame:]:
        frame["repeated_setup"] = True


def branches(ctx):
    """Capture the conditional inputs that canonical command examples skip."""
    host = _host(ctx)
    with ctx.ui("http3-custom-advertisement") as ui:
        first = len(ctx.frames)
        ui.command("set-port-http3")
        ui.menu(r"^443(?:\s|$)")
        ui.menu(r"^On(?:\s|$)")
        _mark_repeated_setup(ctx, first)
        ui.menu(r"^Custom \(manual value\)")
        ui.text(r"Example: h3=[^\r\n]*: ", 'h3=":443"; ma=60')
        ui.menu(r"^Run$", prompt="Review command")
        ui.finish()
    _request(ctx, "http3-custom-advertised", https=True, header='alt-svc: h3=":443"; ma=60')
    _execute(ctx, "set-port-http3", [_m(r"^443(?:\s|$)"), _m(r"^On(?:\s|$)"), _m(r"^Off(?:\s|$)")],
             journey="http3-suppress-advertisement")
    _request(ctx, "http3-no-advertisement", https=True)
    if re.search(r"^alt-svc:", (ctx.evidence / "http3-no-advertisement.headers").read_text(), re.I | re.M):
        raise AssertionError("Alt-Svc remained present after selecting Off")
    ctx.proof("http3-advertisement-suppressed")
    ctx.cli("restore-http3-off", "set-port-http3", "443", "off", "auto")

    # Discover the actual local client address before demonstrating a matching
    # deny. This avoids treating a documentation-only address as a live client.
    ctx.cli("observe-acl-client", "add-backend-header", ctx.domain, "response", "X-Observed-Client", "$remote_addr")
    _request(ctx, "acl-branch-observed-client")
    headers = (ctx.evidence / "acl-branch-observed-client.headers").read_text()
    match = re.search(r"^X-Observed-Client:\s*([^\r\n]+)", headers, re.I | re.M)
    if not match:
        raise AssertionError("No observable client address in the ACL fixture")
    client_ip = str(ipaddress.IPv4Address(match.group(1).strip()))
    ctx.cli("remove-acl-observation", "remove-backend-header", ctx.domain, "response", "X-Observed-Client")
    with ctx.ui("acl-deny-client") as ui:
        first = len(ctx.frames)
        ui.command("add-acl")
        ui.menu(host[1])
        _mark_repeated_setup(ctx, first)
        ui.menu(r"^Layer 7")
        ui.menu(r"^deny(?:\s|$)")
        ui.text(r"ip_list[^\r\n]*: ", client_ip)
        ui.text(r"status_code[^\r\n]*: ", "403")
        ui.menu(r"^Run$", prompt="Review command")
        ui.finish()
    _request(ctx, "acl-client-blocked", expected=403)
    ctx.terminal_command("acl-client-block-verified", ["curl", "--noproxy", "*", "-sS", "-D", "-", "-o", "/dev/null",
                         "http://127.0.0.1", "-H", "Host: " + ctx.domain],
                         require=(r"HTTP/1\.1 403",), title="The explicit address rule rejects this client")
    _execute(ctx, "remove-acl", [_m(re.escape(client_ip))], journey="acl-deny-client-remove")
    _request(ctx, "acl-client-restored")

    with ctx.ui("security-condition-branches") as ui:
        first = len(ctx.frames)
        ui.command("add-security-rule")
        ui.menu(host[1])
        ui.menu(r"^Block when")
        _mark_repeated_setup(ctx, first)
        ui.text(r"Number of conditions[^\r\n]*: ", "5")
        ui.menu(r"^or$", prompt="Condition mode")
        ui.text(r"Status code override[^\r\n]*: ", "403")
        ui.menu(r"^Cookie", prompt="Condition 1 source")
        ui.text(r"Name for cookie: ", "session")
        ui.menu(r"^Exists", prompt="Condition 1 operator")
        ui.menu(r"^Argument", prompt="Condition 2 source")
        ui.text(r"Name for arg: ", "token")
        ui.menu(r"^Equals", prompt="Condition 2 operator")
        ui.text(r"Value for arg [^\r\n]*: ", "demo")
        ui.menu(r"^Variable", prompt="Condition 3 source")
        ui.text(r"Name for var: ", "$request_method")
        ui.menu(r"^Equals", prompt="Condition 3 operator")
        ui.text(r"Value for var [^\r\n]*: ", "POST")
        ui.menu(r"^IP —", prompt="Condition 4 source")
        ui.menu(r"^Real IP", prompt="IP match scope")
        ui.menu(r"^Equals", prompt="Condition 4 operator")
        ui.text(r"Value for ip [^\r\n]*: ", "203.0.113.8")
        ui.menu(r"^Path —", prompt="Condition 5 source")
        ui.menu(r"^Matches", prompt="Condition 5 operator")
        ui.text(r"Value for path [^\r\n]*: ", "^/private/")
        ui.menu(r"^Confirm$", prompt="Security rule summary")
        ui.finish()
    _request(ctx, "condition-branches-nonmatch")
    _request(ctx, "condition-cookie-exists", expected=403, extra=("-H", "Cookie: session=demo"))
    _request(ctx, "condition-argument-matches", expected=403, path="/?token=demo")
    _request(ctx, "condition-variable-matches", expected=403, extra=("-X", "POST"))
    _request(ctx, "condition-path-regex-matches", expected=403, path="/private/demo")
    ctx.cli("matching-ip-rule", "add-security-rule", ctx.domain, "1", "ip", "l3", "equals", client_ip,
            "--action", "block", "--code", "403")
    _request(ctx, "condition-peer-ip-matches", expected=403)
    ctx.cli("remove-matching-ip-rule", "remove-security-rule", "2")
    _request(ctx, "condition-peer-ip-restored")
    ctx.cli("clear-condition-branches", "remove-all-security-rules")

    ctx.cli("condition-replacement-fixture", "add-security-rule", ctx.domain, "1", "header", "User-Agent", "contains", "BadBot",
            "--action", "block", "--code", "404")
    with ctx.ui("security-replace-conditions") as ui:
        first = len(ctx.frames)
        ui.command("update-security-rule")
        ui.menu(re.escape(ctx.domain), first_match=True)
        ui.text(r"Domain [^\r\n]*: ", ctx.domain)
        ui.menu(r"^Block when")
        _mark_repeated_setup(ctx, first)
        ui.text(r"Status code override[^\r\n]*: ", "-")
        ui.menu(r"^Replace$", prompt="Replace conditions")
        ui.text(r"Number of conditions[^\r\n]*: ", "2")
        ui.menu(r"^or$", prompt="Condition mode")
        ui.menu(r"^Header", prompt="Condition 1 source")
        ui.text(r"Header name: ", "User-Agent")
        ui.menu(r"^Contains", prompt="Condition 1 operator")
        ui.text(r"Value for header [^\r\n]*: ", "OtherBot")
        ui.menu(r"^Method", prompt="Condition 2 source")
        ui.menu(r"^Equals", prompt="Condition 2 operator")
        ui.text(r"Value for method [^\r\n]*: ", "POST")
        ui.menu(r"^Run$", prompt="Review command",
                require=(r"Status code: Inherited default", r"Condition 1 — Source: header",
                         r"Condition 1 — Name: User-Agent", r"Condition 1 — Test: contains",
                         r"Condition 1 — Value: OtherBot", r"Condition 2 — Source: method",
                         r"Condition 2 — Test: equals", r"Condition 2 — Value: POST",
                         r"Condition combination: or"))
        ui.finish()
    _request(ctx, "replacement-old-match-cleared", agent="BadBot")
    _request(ctx, "replacement-new-match-blocked", expected=403, agent="OtherBot")
    _request(ctx, "replacement-method-blocked", expected=403, extra=("-X", "POST"))
    _execute(ctx, "list-security-rules", [host], readonly=True, journey="security-replacement-list", require=("OtherBot", "POST"))
    ctx.cli("remove-replacement-rule", "remove-all-security-rules")
    ctx.check_config("security-branches-config")
    _request(ctx, "security-branches-restored")


GROUPS = {
    "headers": (headers, client_ip),
    "access": (access_defaults,),
    "acl": (acl_rules,),
    "rules": (security_rules,),
    "tls": (tls_settings,),
    "certificates": (certificates,),
    "mtls": (mtls,),
    "branches": (branches,),
}


def run(ctx, group=None):
    group = group or os.environ.get("DOCS_SECURITY_GROUP", "all")
    if group != "all" and group not in GROUPS:
        raise ValueError("Unknown security capture group: " + group)
    ctx.ensure_backend(https=True)
    for name, functions in GROUPS.items():
        if group not in ("all", name):
            continue
        for function in functions:
            function(ctx)
