#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/validators.sh
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck source=../lib/utils/ports_runtime.sh
source "$ROOT_DIR/lib/utils/ports_runtime.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

cat >"$tmp_dir/lsof" <<'LSOF'
#!/usr/bin/env bash
exit 1
LSOF
chmod +x "$tmp_dir/lsof"

cat >"$tmp_dir/ss" <<'SS'
#!/usr/bin/env bash
if [ "$1" = "-lnt" ]; then
  cat <<'OUT'
State Recv-Q Send-Q Local Address:Port Peer Address:Port
LISTEN 0      128    *:45678            *:*
OUT
  exit 0
fi
if [ "$1" = "-lntp" ]; then
  cat <<'OUT'
State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0      128    *:45678            *:* users:(("testproc",pid=4321,fd=7))
OUT
  exit 0
fi
exit 1
SS
chmod +x "$tmp_dir/ss"

export PATH="$tmp_dir:$PATH"

if is_host_port_listening 45678 tcp; then
  echo "lsof fallback to ss detected busy port."
else
  echo "Expected lsof fallback to ss to detect busy port." >&2
  exit 1
fi

owner_info="$(port_listener_owner_info 45678 tcp || true)"
if [ "$owner_info" = "4321|testproc" ]; then
  echo "lsof fallback to ss recovered listener owner info."
else
  echo "Expected lsof fallback to ss to report listener owner info, got: ${owner_info:-<empty>}" >&2
  exit 1
fi

if SKIP_DOCKER_CHECKS=true assert_host_port_available_or_fail 45678 tcp >/dev/null 2>&1; then
  echo "SKIP_DOCKER_CHECKS bypasses busy host port preflight."
else
  echo "Expected SKIP_DOCKER_CHECKS=true to bypass busy host port preflight." >&2
  exit 1
fi

if SKIP_DOCKER_CHECKS=true assert_host_port_available_or_fail 45678 tcp "" "" true >/dev/null 2>&1; then
  echo "Expected forced host port preflight to detect busy port." >&2
  exit 1
else
  echo "Forced host port preflight still detects busy port."
fi

cat >"$tmp_dir/lsof" <<'LSOF'
#!/usr/bin/env bash
cat <<'OUT'
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
ChatGPT  111 user   34u  IPv4 0xaaa      0t0  UDP 192.0.2.10:53756->198.51.100.2:443
dnsmasq  222 root    5u  IPv4 0xbbb      0t0  UDP *:444
OUT
LSOF
chmod +x "$tmp_dir/lsof"

if is_host_port_listening 443 udp; then
  echo "Expected remote UDP :443 connection not to count as a local listener." >&2
  exit 1
else
  echo "lsof UDP check ignores remote-only port matches."
fi

if is_host_port_listening 444 udp; then
  echo "lsof UDP check detects local bound port."
else
  echo "Expected lsof UDP check to detect local bound port." >&2
  exit 1
fi

udp_owner_info="$(port_listener_owner_info 444 udp || true)"
if [ "$udp_owner_info" = "222|dnsmasq" ]; then
  echo "lsof UDP owner info uses the local bound port."
else
  echo "Expected lsof UDP owner info for local bound port, got: ${udp_owner_info:-<empty>}" >&2
  exit 1
fi
