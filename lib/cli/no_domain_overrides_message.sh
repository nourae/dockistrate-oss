# shellcheck shell=bash

function no_domain_overrides_message() {
  local msg
  case "$1" in
  remove-backend-client-ip-header)
    msg="[Info] No backend Client IP header overrides configured"
    ;;
  remove-backend-proxy-ip-header)
    msg="[Info] No backend Proxy IP header overrides configured"
    ;;
  remove-backend-header)
    msg="[Info] No backend headers configured"
    ;;
  list-backend-headers)
    msg="[Info] No backends configured"
    ;;
  add-dedicated-host)
    msg="[Info] No eligible backend domains with HTTP/HTTPS mappings configured"
    ;;
  remove-backend-http-version)
    msg="[Info] No backend HTTP version overrides configured"
    ;;
  remove-backend-acl-policy)
    msg="[Info] No backend ACL policy overrides configured"
    ;;
  # unified ACL: no separate L3 policy overrides
  remove-backend-acl-status)
    msg="[Info] No backend ACL status overrides configured"
    ;;
  remove-backend-security-rule-status)
    msg="[Info] No backend security rule status overrides configured"
    ;;
  disable-backend-mtls | replace-backend-ca | remove-backend-ca)
    msg="[Info] No backends with mTLS enabled"
    ;;
  *) return 1 ;;
  esac
  echo "$msg"
  if [ "$INTERACTIVE" = true ]; then
    read -rp "Press Enter to continue..." _
  fi
  return 0
}
