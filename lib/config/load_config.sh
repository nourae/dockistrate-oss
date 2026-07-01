# shellcheck shell=bash

function load_config() {
  if [ ! -f "$GLOBAL_SETTINGS_FILE" ] || [ ! -s "$GLOBAL_SETTINGS_FILE" ]; then
    echo "[Error] Global settings file is missing or empty: ${GLOBAL_SETTINGS_FILE}" >&2
    return 1
  fi

  local header=""
  IFS= read -r header <"$GLOBAL_SETTINGS_FILE" || header=""
  header="${header%$'\r'}"
  if [ "$header" != "$STATE_GLOBAL_SETTINGS_HEADER" ]; then
    echo "[Error] Invalid header in ${GLOBAL_SETTINGS_FILE}. Expected: ${STATE_GLOBAL_SETTINGS_HEADER}" >&2
    return 1
  fi

  config_reset_defaults

  local saw_nginx_image=false
  local saw_certbot_image=false
  local saw_nginx_pull_mode=false
  local saw_certbot_pull_mode=false
  local saw_nginx_directive_strict=false
  local saw_nginx_docker_opts=false
  local saw_visibility_policy=false
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! csv_parse_line "$line"; then
      echo "[Error] Invalid global settings row at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    fi
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_GLOBAL_SETTINGS_COLS" ]; then
      echo "[Error] Invalid global settings column count at line ${line_no}: expected ${STATE_GLOBAL_SETTINGS_COLS}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi
    local key val
    key="${CSV_FIELDS[0]}"
    val="${CSV_FIELDS[1]}"
    case "$key" in
    ENABLE_AUTO_BACKUPS) ENABLE_AUTO_BACKUPS="$val" ;;
    BACKUP_RETENTION) BACKUP_RETENTION="$val" ;;
    ENABLE_BACKUP_COMPRESSION) ENABLE_BACKUP_COMPRESSION="$val" ;;
    HTTP_VERSION) HTTP_VERSION="$val" ;;
    CLIENT_IP_HEADER) CLIENT_IP_HEADER="$val" ;;
    PROXY_IP_HEADER) PROXY_IP_HEADER="$val" ;;
    TLS_PROTOCOLS) TLS_PROTOCOLS="$val" ;;
    TLS_CIPHERS) TLS_CIPHERS="$val" ;;
    SECURITY_RULE_STATUS) SECURITY_RULE_STATUS="$val" ;;
    ACL_STATUS) ACL_STATUS="$val" ;;
    ACL_POLICY) ACL_POLICY="$val" ;;
    TRUSTED_PROXY_RANGES) TRUSTED_PROXY_RANGES="$val" ;;
    REAL_IP_RECURSIVE) REAL_IP_RECURSIVE="$val" ;;
    NGINX_DIRECTIVE_STRICT)
      NGINX_DIRECTIVE_STRICT="$val"
      saw_nginx_directive_strict=true
      ;;
    NGINX_DOCKER_OPTS)
      NGINX_DOCKER_OPTS="$val"
      saw_nginx_docker_opts=true
      ;;
    VISIBILITY_POLICY)
      VISIBILITY_POLICY="$val"
      saw_visibility_policy=true
      ;;
    NGINX_IMAGE)
      NGINX_IMAGE="$val"
      saw_nginx_image=true
      ;;
    CERTBOT_IMAGE)
      CERTBOT_IMAGE="$val"
      saw_certbot_image=true
      ;;
    NGINX_PULL_MODE)
      NGINX_PULL_MODE="$val"
      saw_nginx_pull_mode=true
      ;;
    CERTBOT_PULL_MODE)
      CERTBOT_PULL_MODE="$val"
      saw_certbot_pull_mode=true
      ;;
    esac
  done <"$GLOBAL_SETTINGS_FILE"

  LOAD_CONFIG_SAW_NGINX_IMAGE="$saw_nginx_image"
  LOAD_CONFIG_SAW_CERTBOT_IMAGE="$saw_certbot_image"
  LOAD_CONFIG_SAW_NGINX_PULL_MODE="$saw_nginx_pull_mode"
  LOAD_CONFIG_SAW_CERTBOT_PULL_MODE="$saw_certbot_pull_mode"
  LOAD_CONFIG_SAW_NGINX_DIRECTIVE_STRICT="$saw_nginx_directive_strict"
  LOAD_CONFIG_SAW_NGINX_DOCKER_OPTS="$saw_nginx_docker_opts"
  LOAD_CONFIG_SAW_VISIBILITY_POLICY="$saw_visibility_policy"
}
