# Diagnostics and Traffic Capture

Inspect a running application, explain a failed request, and capture only the
traffic needed for investigation. Start with a configured backend from the
[HTTP walkthrough](backends-and-ports.md).

## Inspect the running configuration

<a id="cmd-status"></a>
<a id="cmd-status-all"></a>
<a id="cmd-check-config"></a>
<a id="cmd-tail-proxy-logs"></a>

1. Open **Diagnostics / troubleshoot → Status**. Read the proxy state,
   backend, listener, and effective access settings. Use **Status All** for
   extended details; these read-only commands have no Run confirmation.
2. Choose **Check Config**. A successful result means Nginx accepts the
   generated configuration; it does not prove that requests reach the app.
3. Send the request below, then choose **Tail Proxy Logs** and enter `20`
   lines. Match the request and response status in the displayed output.
   It continues following new entries; press **Ctrl-C** to stop.

<!-- walkthrough: diagnostics -->

<details>
<summary>status — inputs and result</summary>

1. Command result (start).

   ![Command result (start)](../assets/interactive/operations-inspect-status/05-command-result-earlier-output-2.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-status/05-command-result-earlier-output-2.txt)

2. Command result (continued).

   ![Command result (continued)](../assets/interactive/operations-inspect-status/04-command-result-earlier-output-1.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-status/04-command-result-earlier-output-1.txt)

3. Command result (end).

   ![Command result (end)](../assets/interactive/operations-inspect-status/03-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-status/03-command-result.txt)

</details>

<details>
<summary>status-all — inputs and result</summary>

1. Command result (start).

   ![Command result (start)](../assets/interactive/operations-inspect-status-all/07-command-result-earlier-output-4.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-status-all/07-command-result-earlier-output-4.txt)

2. Command result (continued).

   ![Command result (continued)](../assets/interactive/operations-inspect-status-all/06-command-result-earlier-output-3.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-status-all/06-command-result-earlier-output-3.txt)

3. Command result (continued).

   ![Command result (continued)](../assets/interactive/operations-inspect-status-all/05-command-result-earlier-output-2.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-status-all/05-command-result-earlier-output-2.txt)

4. Command result (continued).

   ![Command result (continued)](../assets/interactive/operations-inspect-status-all/04-command-result-earlier-output-1.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-status-all/04-command-result-earlier-output-1.txt)

5. Command result (end).

   ![Command result (end)](../assets/interactive/operations-inspect-status-all/03-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-status-all/03-command-result.txt)

</details>

<details>
<summary>check-config — inputs and result</summary>

1. Command result.

   ![Command result](../assets/interactive/operations-inspect-check-config/03-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-check-config/03-command-result.txt)

</details>

<details>
<summary>tail-proxy-logs — inputs and result</summary>

1. Enter `20`.

   ![Enter 20](../assets/interactive/operations-inspect-tail-proxy-logs/03-enter-value.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-tail-proxy-logs/03-enter-value.txt)

2. Observe the application request in proxy logs.

   ![Observe the application request in proxy logs](../assets/interactive/operations-inspect-tail-proxy-logs/04-observe-the-application-request-in-proxy-logs.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-tail-proxy-logs/04-observe-the-application-request-in-proxy-logs.txt)

</details>

<details>
<summary>status — inputs and result</summary>

1. Command result (start).

   ![Command result (start)](../assets/interactive/operations-runtime-redacted-status/06-command-result-earlier-output-3.png)

   [Read the captured terminal text](../assets/interactive/operations-runtime-redacted-status/06-command-result-earlier-output-3.txt)

2. Command result (continued).

   ![Command result (continued)](../assets/interactive/operations-runtime-redacted-status/05-command-result-earlier-output-2.png)

   [Read the captured terminal text](../assets/interactive/operations-runtime-redacted-status/05-command-result-earlier-output-2.txt)

3. Command result (continued).

   ![Command result (continued)](../assets/interactive/operations-runtime-redacted-status/04-command-result-earlier-output-1.png)

   [Read the captured terminal text](../assets/interactive/operations-runtime-redacted-status/04-command-result-earlier-output-1.txt)

4. Command result (end).

   ![Command result (end)](../assets/interactive/operations-runtime-redacted-status/03-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-runtime-redacted-status/03-command-result.txt)

</details>

<details>
<summary>status — inputs and result</summary>

1. Command result (start).

   ![Command result (start)](../assets/interactive/operations-runtime-full-status/06-command-result-earlier-output-3.png)

   [Read the captured terminal text](../assets/interactive/operations-runtime-full-status/06-command-result-earlier-output-3.txt)

2. Command result (continued).

   ![Command result (continued)](../assets/interactive/operations-runtime-full-status/05-command-result-earlier-output-2.png)

   [Read the captured terminal text](../assets/interactive/operations-runtime-full-status/05-command-result-earlier-output-2.txt)

3. Command result (continued).

   ![Command result (continued)](../assets/interactive/operations-runtime-full-status/04-command-result-earlier-output-1.png)

   [Read the captured terminal text](../assets/interactive/operations-runtime-full-status/04-command-result-earlier-output-1.txt)

4. Command result (end).

   ![Command result (end)](../assets/interactive/operations-runtime-full-status/03-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-runtime-full-status/03-command-result.txt)

</details>

<details>
<summary>status — inputs and result</summary>

1. Command result (start).

   ![Command result (start)](../assets/interactive/operations-backup-backup-settings-status/06-command-result-earlier-output-3.png)

   [Read the captured terminal text](../assets/interactive/operations-backup-backup-settings-status/06-command-result-earlier-output-3.txt)

2. Command result (continued).

   ![Command result (continued)](../assets/interactive/operations-backup-backup-settings-status/05-command-result-earlier-output-2.png)

   [Read the captured terminal text](../assets/interactive/operations-backup-backup-settings-status/05-command-result-earlier-output-2.txt)

3. Command result (continued).

   ![Command result (continued)](../assets/interactive/operations-backup-backup-settings-status/04-command-result-earlier-output-1.png)

   [Read the captured terminal text](../assets/interactive/operations-backup-backup-settings-status/04-command-result-earlier-output-1.txt)

4. Command result (end).

   ![Command result (end)](../assets/interactive/operations-backup-backup-settings-status/03-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-backup-backup-settings-status/03-command-result.txt)

</details>

<!-- /walkthrough: diagnostics -->

```bash
curl --noproxy '*' -i http://127.0.0.1 -H 'Host: example.com'
```

**Check:** the example responds with 200 and appears in the logs. If it fails,
compare the hostname, listener, access policy, and backend state before changing
settings. Pending file edits need explicit apply; regeneration uses applied state.
**Undo:** inspection changes no application configuration.

CLI equivalents: `./dockistrate.sh status`, `status-all`, `check-config`, and
`tail-proxy-logs 20`.

## Change access log fields

<a id="cmd-list-log-fields"></a>
<a id="cmd-add-log-field"></a>
<a id="cmd-update-log-field"></a>
<a id="cmd-move-log-field"></a>
<a id="cmd-remove-log-field"></a>

Open **Advanced command browser → Logging**. List the fields first so you can
identify the position to edit; IDs can change after a removal or move.

| Action | Inputs and review | Check the result |
| --- | --- | --- |
| **List Log Fields** | No inputs | Read the numbered field list. |
| **Add Log Field** | Choose `$request_time`; choose its position; review → **Run** | Repeat a request and inspect its duration field. |
| **Update Log Field** | Select its ID, then the replacement field; review → **Run** | The field at that position changes. |
| **Move Log Field** | Select source and destination positions; review → **Run** | Re-list and inspect the new order. |
| **Remove Log Field** | Select the added field's current ID; review → **Run** | Re-list to confirm the example field is removed. |

<!-- walkthrough: log-fields -->

<details>
<summary>list-log-fields — inputs and result</summary>

1. Command result.

   ![Command result](../assets/interactive/operations-inspect-list-log-fields/03-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-list-log-fields/03-command-result.txt)

</details>

<details>
<summary>add-log-field — inputs and result</summary>

1. Enter `$request_time`.

   ![Enter $request_time](../assets/interactive/operations-inspect-add-log-field/03-enter-value.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-add-log-field/03-enter-value.txt)

2. Press Enter to accept the displayed default or leave the optional value blank.

   ![Press Enter to accept the displayed default or leave the optional value blank](../assets/interactive/operations-inspect-add-log-field/04-enter-value.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-add-log-field/04-enter-value.txt)

3. Review the collected inputs, then choose **Run**.

   ![Review the collected inputs, then choose Run](../assets/interactive/operations-inspect-add-log-field/05-run.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-add-log-field/05-run.txt)

4. Command result.

   ![Command result](../assets/interactive/operations-inspect-add-log-field/06-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-add-log-field/06-command-result.txt)

</details>

<details>
<summary>list-log-fields — inputs and result</summary>

1. Command result.

   ![Command result](../assets/interactive/operations-inspect-list-log-fields--session-002/03-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-list-log-fields--session-002/03-command-result.txt)

</details>

<details>
<summary>update-log-field — inputs and result</summary>

1. Choose **$request_time**.

   ![Choose $request_time](../assets/interactive/operations-inspect-update-log-field/03-request-time.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-update-log-field/03-request-time.txt)

2. Enter `$upstream_response_time`.

   ![Enter $upstream_response_time](../assets/interactive/operations-inspect-update-log-field/04-enter-value.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-update-log-field/04-enter-value.txt)

3. Review the collected inputs, then choose **Run**.

   ![Review the collected inputs, then choose Run](../assets/interactive/operations-inspect-update-log-field/05-run.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-update-log-field/05-run.txt)

4. Command result.

   ![Command result](../assets/interactive/operations-inspect-update-log-field/06-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-update-log-field/06-command-result.txt)

</details>

<details>
<summary>move-log-field — inputs and result</summary>

1. Enter `9`.

   ![Enter 9](../assets/interactive/operations-inspect-move-log-field/03-enter-value.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-move-log-field/03-enter-value.txt)

2. Enter `1`.

   ![Enter 1](../assets/interactive/operations-inspect-move-log-field/04-enter-value.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-move-log-field/04-enter-value.txt)

3. Review the collected inputs, then choose **Run**.

   ![Review the collected inputs, then choose Run](../assets/interactive/operations-inspect-move-log-field/05-run.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-move-log-field/05-run.txt)

4. Command result.

   ![Command result](../assets/interactive/operations-inspect-move-log-field/06-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-move-log-field/06-command-result.txt)

</details>

<details>
<summary>list-log-fields — inputs and result</summary>

1. Command result.

   ![Command result](../assets/interactive/operations-inspect-list-log-fields--session-003/03-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-list-log-fields--session-003/03-command-result.txt)

</details>

<details>
<summary>remove-log-field — inputs and result</summary>

1. Choose **$upstream_response_time**.

   ![Choose $upstream_response_time](../assets/interactive/operations-inspect-remove-log-field/03-upstream-response-time.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-remove-log-field/03-upstream-response-time.txt)

2. Review the collected inputs, then choose **Run**.

   ![Review the collected inputs, then choose Run](../assets/interactive/operations-inspect-remove-log-field/04-run.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-remove-log-field/04-run.txt)

3. Enter `YES`.

   ![Enter YES](../assets/interactive/operations-inspect-remove-log-field/05-enter-value.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-remove-log-field/05-enter-value.txt)

4. Command result.

   ![Command result](../assets/interactive/operations-inspect-remove-log-field/06-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-remove-log-field/06-command-result.txt)

</details>

<details>
<summary>list-log-fields — inputs and result</summary>

1. Command result.

   ![Command result](../assets/interactive/operations-inspect-log-fields-restored/03-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-log-fields-restored/03-command-result.txt)

</details>

<details>
<summary>check-config — inputs and result</summary>

1. Configuration test passed.

   ![Configuration test passed](../assets/interactive/operations-inspect-logging-config/03-configuration-test-passed.png)

   [Read the captured terminal text](../assets/interactive/operations-inspect-logging-config/03-configuration-test-passed.txt)

</details>

<!-- /walkthrough: log-fields -->

**CLI equivalent:** `./dockistrate.sh list-log-fields` and
`./dockistrate.sh add-log-field '$request_time'`. Quote `$` so your shell does not
expand the Nginx variable. For update, move, and removal, use the IDs from the
current list. Keep required application log fields when undoing your example.

## Capture and stop traffic

<a id="cmd-start-capture"></a>
<a id="cmd-stop-capture"></a>

1. Open **Advanced command browser → Traffic Capture → Start Capture**.
   Choose an output folder and review **Run**. The operation then asks for the
   capture scope; choose the backend scope and select the demo backend.
2. Send a request to the demo while capture is running. Capture only synthetic
   traffic for a documentation example.
3. Choose **Stop Capture**; its review shows `(none)` because it takes no
   arguments. Choose **Run**. Inspect the capture output using
   `tcpdump -r <capture-file>` or Wireshark; identify the request's endpoint and
   packets. A created file alone is not proof that the desired traffic was captured.

<!-- walkthrough: traffic-capture -->

<details>
<summary>start-capture — Capture one backend</summary>

1. Enter `documentation-example`.

   ![Enter documentation-example](../assets/interactive/operations-traffic-traffic-capture/03-enter-value.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-traffic-capture/03-enter-value.txt)

2. Review the collected inputs, then choose **Run**.

   ![Review the collected inputs, then choose Run](../assets/interactive/operations-traffic-traffic-capture/04-run.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-traffic-capture/04-run.txt)

3. Choose **Specific backend(s)**.

   ![Choose Specific backend(s)](../assets/interactive/operations-traffic-traffic-capture/05-specific-backend-s.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-traffic-capture/05-specific-backend-s.txt)

4. Enter `example.com`.

   ![Enter example.com](../assets/interactive/operations-traffic-traffic-capture/06-enter-value.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-traffic-capture/06-enter-value.txt)

5. Enter `n`.

   ![Enter n](../assets/interactive/operations-traffic-traffic-capture/07-enter-value.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-traffic-capture/07-enter-value.txt)

6. Command result.

   ![Command result](../assets/interactive/operations-traffic-traffic-capture/08-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-traffic-capture/08-command-result.txt)

</details>

<details>
<summary>stop-capture — inputs and result</summary>

1. Review the collected inputs, then choose **Run**.

   ![Review the collected inputs, then choose Run](../assets/interactive/operations-traffic-stop-capture/03-run.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-stop-capture/03-run.txt)

2. Command result.

   ![Command result](../assets/interactive/operations-traffic-stop-capture/04-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-stop-capture/04-command-result.txt)

</details>

<details>
<summary>Read the captured demo packets</summary>

1. Read the captured demo packets.

   ![Read the captured demo packets](../assets/interactive/operations-traffic-packet-inspection/01-read-the-captured-demo-packets.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-packet-inspection/01-read-the-captured-demo-packets.txt)

</details>

<details>
<summary>start-capture — Capture and decrypt HTTPS</summary>

1. Enter `documentation-tls-example`.

   ![Enter documentation-tls-example](../assets/interactive/operations-traffic-tls-traffic-capture/03-enter-value.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-tls-traffic-capture/03-enter-value.txt)

2. Review the collected inputs, then choose **Run**.

   ![Review the collected inputs, then choose Run](../assets/interactive/operations-traffic-tls-traffic-capture/04-run.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-tls-traffic-capture/04-run.txt)

3. Choose **All Nginx traffic (clients and backends)**.

   ![Choose All Nginx traffic (clients and backends)](../assets/interactive/operations-traffic-tls-traffic-capture/05-all-nginx-traffic-clients-and-backends.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-tls-traffic-capture/05-all-nginx-traffic-clients-and-backends.txt)

4. Enter `y`.

   ![Enter y](../assets/interactive/operations-traffic-tls-traffic-capture/06-enter-value.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-tls-traffic-capture/06-enter-value.txt)

5. Command result.

   ![Command result](../assets/interactive/operations-traffic-tls-traffic-capture/07-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-tls-traffic-capture/07-command-result.txt)

</details>

<details>
<summary>stop-capture — Stop HTTPS capture</summary>

1. Review the collected inputs, then choose **Run**.

   ![Review the collected inputs, then choose Run](../assets/interactive/operations-traffic-stop-tls-capture/03-run.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-stop-tls-capture/03-run.txt)

2. Command result.

   ![Command result](../assets/interactive/operations-traffic-stop-tls-capture/04-command-result.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-stop-tls-capture/04-command-result.txt)

</details>

<details>
<summary>Read the decrypted HTTPS request</summary>

1. Read the decrypted HTTPS request.

   ![Read the decrypted HTTPS request](../assets/interactive/operations-traffic-tls-packet-inspection/01-read-the-decrypted-https-request.png)

   [Read the captured terminal text](../assets/interactive/operations-traffic-tls-packet-inspection/01-read-the-decrypted-https-request.txt)

</details>

<!-- /walkthrough: traffic-capture -->

**Check:** capture status becomes inactive and the saved packet file contains
traffic for the selected backend. **Undo:** Stop Capture ends the capture;
remove an exported demo capture only after inspection. TLS-decrypt mode also
collects sensitive TLS session keys; its options, limits, and verification are
in [TLS decrypt capture](#tls-decrypt-capture).

For the TLS example, start another capture in `documentation-tls-example`,
choose **All Nginx traffic**, and answer `y` to **Enable TLS decrypt capture**.
Send an HTTPS request, then stop the capture. Open the saved packet file with
its session key log in Wireshark and filter `tcp.port == 443 && http.request`;
seeing the HTTPS request here verifies decryption of the client connection.
These files have restricted permissions. Use the owning operator account, or
make private, owner-only copies for your analyzer while preserving the original
permissions; remove those inspection copies afterward.
Keep session keys private and confirm a fresh HTTPS request still works after
capture stops.

**CLI equivalent:**

```bash
./dockistrate.sh start-capture --scope backends --backends example.com
./dockistrate.sh stop-capture
```

## Detailed reference

## Common Commands

```text
status
status-all
check-config
tail-proxy-logs
list-backends
list-port-mappings
list-log-fields
add-log-field <field> [position]
update-log-field <id> <field>
remove-log-field <id>
move-log-field <from> <to>

start-capture [folder] [--scope all|backends|clients|clients-backends] [--backends "domain..."] [--clients "ip..."] [--tls-decrypt]
stop-capture
```

Log-field IDs and positions are decimal in CLI and interactive mode: `010`
selects field 10 and `08` selects field 8. Moving a field preserves every other
field and its relative order.

## Status and Config Checks

```bash
./dockistrate.sh status
./dockistrate.sh status-all
./dockistrate.sh check-config
```

`status` shows the default operator dashboard: proxy/backend state, capture
state, backup posture, headers, TLS overrides, Nginx directives, port mappings,
ACL/security rules, and a host-wide container table.

`status-all` adds details such as access log fields, backend Docker options,
path options, and certificate inventory.

Docker option, header, and generic Nginx directive values are visible by default.
Select `set-visibility-policy redacted` before collecting a support transcript to
hide these values in Dockistrate status/list output, command previews, success
messages, and audit/verbose command entries in both CLI and interactive mode.
The policy also skips affected interactive recents/favorites. It does not change
execution inputs, stored state, or generated Nginx configuration.

## Logs

Visibility policy applies to Dockistrate's command copies, not arbitrary proxy
or backend log content. It does not erase existing logs or saved history, nor
sanitize shell history, process arguments, captures, or TLS key logs. Review
those artifacts before sharing them. Interactive keyboard input can still be visible on the terminal; see
[operator value visibility](advanced-nginx-docker-options.md#operator-value-visibility).

Dockistrate's own `state/logs/docker_manager.log`, `audit.log`, and `audit.log.1`
are owner-only (`600`), including existing copies tightened during runtime
preparation or permission repair. Log writes require private access; if that
cannot be established, the message is not appended or echoed as an error
fallback. This does not suppress ordinary operator output selected by `full`.
Group-based collectors must run with the owning account's access or consume an
explicitly controlled export; see the
[upgrade note](backups-restore-cleanup.md#saved-history-and-log-access-after-upgrade).

Audit entries record attempted runtime commands, including failed commands,
with values selected by the active visibility policy. Permission repair and
other pre-runtime commands do not append audit entries. An audit log exceeding 1 MiB rotates
on the next write to one `audit.log.1`; application logs have no built-in
rotation. Neither has age-based expiry. Backend/header removal does not purge
these files. Use [explicit cleanup](backups-restore-cleanup.md#saved-command-and-log-cleanup)
when their retention is no longer wanted, and manage collected copies separately.

Before starting the log tail, ensure both ACL address layers permit the test
request. An isolated **public demo** can use
`./dockistrate.sh set-backend-acl-policy example.com allow`; this opens both
layers only for that domain. Private services should retain `deny` and configure
both [client and original-peer allowances](access-control-security-rules.md#address-layers-and-private-services).
Docker may translate a local request to a bridge address, so a loopback-only
allowance is unreliable.

Then tail proxy logs in one terminal while sending test requests from another:

```bash
# Terminal 1
./dockistrate.sh tail-proxy-logs
```

```bash
# Terminal 2
curl --noproxy '*' -i http://127.0.0.1 -H 'Host: example.com'
```

Customize access log fields:

```bash
./dockistrate.sh list-log-fields
./dockistrate.sh add-log-field '$request_time'
./dockistrate.sh update-log-field 3 '$upstream_response_time'
./dockistrate.sh remove-log-field 3
```

### Verbose trace timing

Use `./dockistrate.sh -v <command> ...` for a CLI trace or
`./dockistrate.sh -v -i` for a traced interactive session. The existing visibility
policy still controls sensitive output; this timing change preserves the same
command trace detail and `[CMD]` marker.

Interactive log capture starts only after selecting a runtime command and stops
before returning to the picker. Selecting permission repair, replaying an older
saved repair command, or quitting the initial picker does not start log capture
or runtime initialization. Existing saved-history files still require private
access when the picker reads them.

Each trace block starts with one wall-clock anchor including its timezone
offset. Later prefixes identify the shell session and elapsed whole seconds:

```text
+ [session=123 elapsed=0s] [CMD] : 'Verbose trace session 123 started at 2026-10-17 21:00:00 +0000; offsets are elapsed whole seconds'
+ [session=123 elapsed=3s] [CMD] run_command status
```

`session` identifies the Dockistrate shell process. `elapsed` measures time
since the current trace block started, including time spent in that command's
interactive prompts; it is not the duration of the command printed on that line.
Each runtime command selected in the picker starts a new block and anchor,
retaining the same shell-session ID. The start anchor
uses the same trace destination as the following lines, even when ordinary
application logging is disabled. Bash's built-in elapsed counter avoids running
an external clock command for each trace line and works with macOS Bash 3.

This changes the diagnostic prefix used in 1.0.1: tools that previously parsed
a calendar timestamp before `[CMD]` on every line must instead read the session
anchor and elapsed field. Normal audit/application-log timestamps remain
unchanged. No flags, interactive workflows, or saved-state formats change.

## Packet Capture

Start a scoped capture:

```bash
./dockistrate.sh start-capture capture-test \
  --scope clients-backends \
  --clients "203.0.113.10" \
  --backends "example.com"
```

The example requires `example.com` to be a configured backend with a resolvable
capture target. Scope selection has the same meaning in CLI and interactive
mode:

| Scope | Required selection |
| --- | --- |
| `all` | Full traffic; do not supply backend or client restrictions. |
| `backends` | Configured backend domains. Omitting the backend list selects all configured backends. |
| `clients` | One or more valid IPv4 addresses. |
| `clients-backends` | Both a backend selection and one or more valid client IPv4 addresses. Omitting the backend list selects all configured backends. |

Without `--scope`, supplied backend/client lists select the corresponding scope;
without either list, CLI mode captures all traffic. Lists accept commas or
whitespace. Domain names are normalized, and repeated targets are deduplicated.
The existing case-insensitive scope aliases remain supported.

Unknown options or scopes, missing option values, explicitly empty target
lists, unknown backend domains, unusable backend targets, and restrictions that
contradict the selected scope return an error. A combined request must resolve
both restrictions. Invalid requests do not replace an existing capture, enable
TLS decrypt mode, or restart the proxy. In the interactive picker, selecting a
client scope requires a nonempty client list; a blank backend selection means
all configured backends, and no configured backends is an error for a backend
scope. End-of-input cancels an interactive request, including a partially typed
selection; submit an empty backend line with Enter to select all configured
backends intentionally.

Backend selections require a saved container identity with matching ownership.
Their IP addresses come from the verified immutable container ID; a foreign
container with the expected name is rejected before capture changes. A verified
stopped backend still supplies its configured ports without runtime IPs. For
existing backends without identity metadata, complete the explicit
[backend upgrade](backends-and-ports.md#backend-identity-and-upgrades) first.

Combined filters require a packet to match both the client expression and the
complete backend expression. Backend expressions match ports and IP addresses,
not HTTP `Host` headers: shared listener/upstream ports can match traffic for
more than one backend. Packet-level filtering does not provide isolation
between domains sharing those endpoints.

For intentional full capture, use:

```bash
./dockistrate.sh start-capture capture-all --scope all
```

### Output directories and replacement

`--folder capture-all` is equivalent to the positional folder. Output remains
under `state/pcaps`; the `pcaps/...` and `state/pcaps/...` aliases are supported.
Folder resolution retains literal filename characters through the containment
check and container mount, including embedded or trailing newlines. A similarly
named sibling is a different folder. This applies to CLI and picker execution.

Capture preparation uses Bash 3 and standard filesystem tools; it has no host
Python dependency. Directory operations retain a verified working-directory
handle so replacing a pathname cannot redirect a later write.
Every existing component of the normalized output path must be a physical
directory: symlinks are rejected even when their targets remain inside the
capture tree. The fixed macOS `/tmp` and `/var` system aliases are supported.
Missing nested directories are created with private permissions. The
`state/pcaps/tls-keys` directory and its descendants (including case variants of
`tls-keys`) are reserved for TLS session keys and cannot be selected as packet
output, because the proxy may still write that subtree during capture replacement.
This also excludes alternate spellings that the filesystem resolves to the same
directory; distinct Unicode folder names remain supported.

Capture start and stop share the configuration mutation lock. Validation of
options, targets, output paths, proxy state, and TLS consent happens before the
existing capture is removed. Replacement then removes the old container by its
immutable ID and verifies its absence before creating or changing output
directories. Filesystem operations reject symlink traversal and verify directory
identity again before Docker receives the bind source. A removal or verification
failure aborts the launch. If a later step fails after removal, the previous
packet capture is not restarted; existing capture files are retained. The TLS
recovery rules below still apply.

When upgrading from 1.0.1, replace a symlink-based output selection with its
physical path inside `state/pcaps`, choose another folder if it was beneath
`tls-keys`, and retry capture with that physical selection.
Existing capture files, filenames, folder layout, and saved-state formats need
no migration. Command flags and interactive choices are unchanged.

### TLS decrypt capture

The optional `--tls-decrypt` flag retains its separate acknowledgement flow.
An existing, active TLS decrypt session reuses its state and key log. If saved
TLS decrypt state or the installed helper version does not match the running
proxy, the request fails before changing either. After updating Dockistrate,
stop and re-enable an existing TLS decrypt capture to recreate the proxy with
the current helper. Repeat your intended scope and target options:

```bash
./dockistrate.sh stop-capture
./dockistrate.sh start-capture capture-test \
  --scope clients-backends \
  --clients "203.0.113.10" \
  --backends "example.com" \
  --tls-decrypt
```

These commands briefly replace the proxy and preserve previous key logs. In
interactive mode, select `stop-capture`, then `start-capture` with the desired
scope and TLS decrypt enabled. Command names, flags, and saved-state formats
are unchanged.

For a new TLS decrypt session, failure to launch the capture restores the prior
TLS state and proxy mode. Cleanup removes only a capture container created by
that attempt. If runtime recovery cannot finish, the command reports the
failure and retains recovery state instead of claiming key logging is disabled.
Key logs use unique private filenames, so another attempt in the same second
cannot overwrite an earlier log. Logs from failed attempts remain available
with restricted permissions, just as logs remain after `stop-capture`.

TLS key recording supports normal HTTPS handshakes with SNI hostname selection
and Nginx workers running as a non-root user. During standard Nginx startup, the
privileged master opens the private key log before creating workers. Workers
inherit that open file and can append records after dropping privileges; the
key directory and file retain modes `700` and `600` and their existing owners.
Custom images must support the OpenSSL key-log callbacks and allow the Nginx
process to open the private log at startup.

Confirm that a key log contains actual TLS records after making a new HTTPS
connection before relying on it for decryption. An empty or header-only file
does not confirm recording. Keep its private permissions intact.

Compatibility: requests that previously silently fell back to a wider scope now
fail. Correct the option/scope/target instead of relying on that fallback, or
explicitly select full capture without target restrictions. Existing capture
files and saved-state formats need no migration.

Inspect and stop capture:

```bash
./dockistrate.sh status-all
./dockistrate.sh stop-capture
```

Captures and temporary capture state live under `state/pcaps` and `state/tmp`.
Do not commit captures from real environments.

## Verification

```bash
./dockistrate.sh status
./dockistrate.sh check-config
./dockistrate.sh status-all
```

When investigating a live routing issue, prefer Dockistrate status and log
commands first, then fall back to direct Docker commands only for details the
tool does not expose.
