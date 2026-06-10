#!/usr/bin/env bash

oneTimeSetUp() {
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/security-ip-update.XXXXXX")"
  STATE_DIR="$TMP_ROOT/state"
  CONFIG_DIR="$STATE_DIR/config"
  mkdir -p "$CONFIG_DIR"

  BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
  cat >"$BACKEND_PORTS_FILE" <<'EOF_BACKENDS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,127.0.0.1:18180,dockistrate-net,,,,,,,,,,,,,,,,,
backend,valid.test,127.0.0.1:9090,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_BACKENDS

  SECURITY_IP_RULES_FILE="$CONFIG_DIR/security_ip_rules.csv"
  SECURITY_IP_RULES_DB="$SECURITY_IP_RULES_FILE"
  SEED_RULE_FILE="$CONFIG_DIR/security_ip_rules.seed"
  cat >"$SEED_RULE_FILE" <<'EOF_RULE'
enabled,domain,scope,action,ip_value,status_code
1,example.com,l7,allow,192.0.2.10,200
EOF_RULE
  cp "$SEED_RULE_FILE" "$SECURITY_IP_RULES_DB"
}
