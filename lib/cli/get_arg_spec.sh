# shellcheck shell=bash

#######################################
# Argument Specifications for Interactive Picker
#######################################
function get_arg_spec() {
  local cmd="$1"
  case "$cmd" in
  start-nginx)
    echo "nginx_image,$NGINX_IMAGE;docker_opts,"
    ;;
  set-certbot-image)
    echo "certbot_image,$CERTBOT_IMAGE"
    ;;
  add-backend)
    echo "domain,;image,;container_port,;protocol,http;listen,;cert_path,;ws,no;docker_opts,;network,$DEFAULT_NETWORK;expose,yes"
    ;;
  add-host-alias)
    echo "alias,;domain,"
    ;;
  add-dedicated-host)
    echo "hostname,;domain,;inherit_mtls,yes;inherit_acl,yes;inherit_security_rules,yes;inherit_headers,yes;inherit_paths,yes"
    ;;
  remove-backend | start-backend | stop-backend | restart-backend)
    echo "domain,"
    ;;
  restart-all-backends)
    echo ""
    ;;
  remove-all-backends)
    echo ""
    ;;
  remove-host-alias)
    echo "alias,"
    ;;
  remove-dedicated-host)
    echo "hostname,"
    ;;
  list-host-aliases)
    echo "domain,"
    ;;
  list-dedicated-hosts)
    echo "domain,"
    ;;
  set-dedicated-host-inherit)
    echo "hostname,;setting,;value,yes"
    ;;
  show-dedicated-host-inherit)
    echo "hostname,"
    ;;
  update-backend)
    echo "domain,;image,;container_port,;docker_opts,;network,$DEFAULT_NETWORK"
    ;;
  replace-backend-network)
    echo "domain,;network,$DEFAULT_NETWORK"
    ;;
  add-cert)
    echo "domain,;port_suffix,443;cert_choice,selfsigned;upload_fullchain,;upload_privkey,"
    ;;
  replace-cert)
    echo "domain,;port_suffix,443;cert_choice,selfsigned;upload_fullchain,;upload_privkey,"
    ;;
  remove-cert)
    echo "domain,;port_suffix,443"
    ;;
  add-port)
    echo "domain,;nginx_port,;container_port,;protocol,http;cert_path,none;ws,no;http3,off;alt_svc,auto"
    ;;
  remove-port)
    echo "domain,;nginx_port,"
    ;;
  update-port)
    if [ "$INTERACTIVE" = true ]; then
      echo "domain,"
    else
      echo "domain,;nginx_port,;container_port,;protocol,http;cert_path,none;ws,$(get_backend_ws_flag '');http3,off;alt_svc,auto"
    fi
    ;;
  set-port-http3)
    echo "port,;http3,on;alt_svc,auto"
    ;;
  list-port-http3)
    echo "port,"
    ;;
  add-path-option)
    echo "domain,;nginx_port,;path_prefix,;ws,inherit;redirect,inherit;headers,none;match,prefix;priority,100;target,;rewrite,none;reason,-;loc,auto"
    ;;
  update-path-option)
    echo "domain,;nginx_port,;path_prefix,;new_path,;new_nginx_port,;ws,;redirect,;headers,;match,;priority,;target,;rewrite,;reason,;loc,"
    ;;
  remove-path-option)
    echo "domain,;nginx_port,;path_prefix,"
    ;;
  remove-all-path-options)
    echo "domain,"
    ;;
  list-path-options)
    echo "domain,;nginx_port,"
    ;;
  set-port-redirect)
    echo "domain,;port,;on_off,off;code,301"
    ;;
  remove-port-redirect)
    echo "domain,;port,"
    ;;
  list-port-mappings)
    echo ""
    ;;
  enable-ws | disable-ws)
    echo "domain,;port,"
    ;;
  clean-all)
    echo "domain,"
    ;;
  uninstall-all)
    echo "uninstall_scope,backend"
    ;;
  set-nginx-directive)
    echo "directive_scope,global;domain,;port,;path_prefix,;directive_name,;directive_value,"
    ;;
  set-nginx-directive-raw)
    echo "directive_scope,global;domain,;port,;path_prefix,;directive_name,;directive_value,"
    ;;
  remove-nginx-directive)
    echo "directive_scope,global;domain,;port,;path_prefix,;directive_name,"
    ;;
  remove-all-nginx-directives | list-nginx-directives)
    echo "directive_scope,all;domain,;port,;path_prefix,"
    ;;
  list-nginx-directive-catalog)
    echo ""
    ;;
  set-nginx-directive-strict)
    echo "on_off,$NGINX_DIRECTIVE_STRICT"
    ;;
  show-nginx-directive-strict)
    echo ""
    ;;
  control-server-tokens)
    echo "on_off,"
    ;;
  show-server-tokens)
    echo ""
    ;;
  set-client-ip-header)
    echo "header_or_off,$CLIENT_IP_HEADER"
    ;;
  set-backend-client-ip-header)
    echo "domain,;header_or_off,$(get_backend_client_ip_header '')"
    ;;
  remove-backend-client-ip-header)
    echo "domain,"
    ;;
  set-proxy-ip-header)
    echo "header_or_off,$PROXY_IP_HEADER"
    ;;
  set-backend-proxy-ip-header)
    echo "domain,;header_or_off,$(get_backend_proxy_ip_header '')"
    ;;
  remove-backend-proxy-ip-header)
    echo "domain,"
    ;;
  add-header)
    echo "req_resp,request;header,;value,"
    ;;
  update-header)
    echo "req_resp,request;header,;value,"
    ;;
  remove-header)
    echo "req_resp,request;header,"
    ;;
  list-headers)
    echo ""
    ;;
  remove-all-headers)
    echo ""
    ;;
  # security-ip commands are internal aliases; not exposed in picker
  add-backend-header)
    echo "domain,;req_resp,request;header,;value,"
    ;;
  update-backend-header)
    echo "domain,;req_resp,request;header,;value,"
    ;;
  remove-backend-header)
    echo "domain,;req_resp,request;header,"
    ;;
  remove-all-backend-headers)
    echo "domain,"
    ;;
  list-backend-headers)
    echo "domain,"
    ;;
  set-hsts)
    echo "hsts_value,"
    ;;
  set-backend-hsts)
    echo "domain,;backend_hsts_value,"
    ;;
  set-csp)
    echo "csp_value,"
    ;;
  set-backend-csp)
    echo "domain,;backend_csp_value,"
    ;;
  list-log-fields)
    echo ""
    ;;
  add-log-field)
    echo "field,;position,"
    ;;
  remove-log-field)
    echo "id,"
    ;;
  update-log-field)
    echo "id,;field,"
    ;;
  move-log-field)
    echo "from,;to,"
    ;;
  set-backend-http-version)
    echo "domain,;version,$HTTP_VERSION"
    ;;
  remove-backend-http-version)
    echo "domain,"
    ;;
  set-port-tls-protocols)
    echo "port,;protocols,$TLS_PROTOCOLS"
    ;;
  remove-port-tls-protocols)
    echo "port,"
    ;;
  set-port-tls-ciphers)
    echo "port,;ciphers,$TLS_CIPHERS"
    ;;
  remove-port-tls-ciphers)
    echo "port,"
    ;;
  enable-backend-mtls)
    echo "domain,;client_name,"
    ;;
  disable-backend-mtls)
    echo "domain,"
    ;;
  add-backend-client-cert)
    echo "domain,;client_name,"
    ;;
  revoke-backend-client-cert)
    echo "domain,;client_name,"
    ;;
  remove-backend-client-cert)
    echo "domain,;client_name,"
    ;;
  list-backend-client-certs)
    echo "domain,"
    ;;
  replace-backend-client-cert)
    echo "domain,;client_name,"
    ;;
  export-backend-client-p12)
    echo "domain,;client_name,"
    ;;
  list-backend-cas)
    echo ""
    ;;
  replace-backend-ca)
    echo "domain,"
    ;;
  remove-backend-ca)
    echo "domain,"
    ;;
  set-backend-acl-policy)
    echo "domain,;policy,$ACL_POLICY"
    ;;
  remove-backend-acl-policy)
    echo "domain,"
    ;;
  # unified ACL: no separate L3 policy in picker
  set-backend-acl-status)
    echo "domain,;code,$ACL_STATUS"
    ;;
  remove-backend-acl-status)
    echo "domain,"
    ;;
  set-backend-security-rule-status)
    echo "domain,;code,$SECURITY_RULE_STATUS"
    ;;
  remove-backend-security-rule-status)
    echo "domain,"
    ;;
  add-acl)
    echo "domain,;scope,l7;allow_or_deny,;ip_list,;status_code,$ACL_STATUS"
    ;;
  remove-acl)
    echo "id,"
    ;;
  disable-acl | enable-acl)
    echo "id,"
    ;;
  remove-all-acl | disable-all-acl | enable-all-acl)
    echo ""
    ;;
  update-acl)
    if [ "$INTERACTIVE" = true ]; then
      echo "id,"
    else
      echo "id,;domain,;allow_or_deny,;ip,;status_code,$ACL_STATUS"
    fi
    ;;
  fix-permissions)
    echo "mode,__DEFAULT__"
    ;;
  upgrade-preflight)
    echo "target_tag,;require_backup,no"
    ;;
  # unified ACL: legacy L3 ACL commands removed
  # These commands require no arguments
  start-nginx | stop-nginx | remove-nginx | update-nginx-config | status | status-all | list-backends | fix-default-config | start-all-backends | stop-all-backends | restart-all-backends | remove-all-backends | list-certs | renew-certs | list-backups | list-acl | remove-all-acl | disable-all-acl | enable-all-acl | list-security-rules | remove-all-security-rules | disable-all-security-rules | enable-all-security-rules | list-log-fields | check-config | stop-capture | list-backend-cas | help-update)
    echo ""
    ;;
  move-acl-rule | move-security-rule)
    echo "from,;to,"
    ;;
  add-security-rule)
    # Interactive flow handles dynamic groups; only need domain here
    echo "domain,"
    ;;
  remove-all-security-rules | disable-all-security-rules | enable-all-security-rules)
    echo ""
    ;;
  # legacy operator-specific commands removed
  remove-security-rule)
    echo "id,"
    ;;
  disable-security-rule | enable-security-rule)
    echo "id,"
    ;;
  update-security-rule)
    echo "id,"
    ;;
  set-security-rule-mode)
    echo "id,;mode,and"
    ;;
  duplicate-security-rule)
    echo "id,"
    ;;
  # legacy operator-specific commands removed
  restore-backup)
    echo "backup,"
    ;;
  create-backup)
    echo "desc,ManualBackup"
    ;;
  set-auto-backups)
    echo "true_or_false,$ENABLE_AUTO_BACKUPS"
    ;;
  set-backup-retention)
    echo "days,$BACKUP_RETENTION"
    ;;
  set-backup-compression)
    echo "true_or_false,$ENABLE_BACKUP_COMPRESSION"
    ;;
  set-http-version)
    echo "version,$HTTP_VERSION"
    ;;
  set-tls-protocols)
    echo "protocols,$TLS_PROTOCOLS"
    ;;
  set-tls-ciphers)
    echo "ciphers,$TLS_CIPHERS"
    ;;
  set-security-rule-status)
    echo "code,$SECURITY_RULE_STATUS"
    ;;
  set-acl-status)
    echo "code,$ACL_STATUS"
    ;;
  set-acl-policy)
    echo "policy,$ACL_POLICY"
    ;;
  # unified ACL: no separate L3 ACL policy prompt
  set-trusted-proxies)
    echo "ranges,$TRUSTED_PROXY_RANGES"
    ;;
  set-real-ip-recursive)
    echo "on_off,$REAL_IP_RECURSIVE"
    ;;
  set-nginx-docker-opts)
    echo "docker_opts,"
    ;;
  show-nginx-docker-opts)
    echo ""
    ;;
  set-visibility-policy)
    echo "visibility_policy,$VISIBILITY_POLICY"
    ;;
  show-visibility-policy)
    echo ""
    ;;
  set-nginx-image)
    echo "nginx_image,$NGINX_IMAGE"
    ;;
  tail-proxy-logs)
    echo "lines,200"
    ;;
  start-capture)
    echo "folder,$CAPTURE_DIR"
    ;;
  *)
    return 1
    ;;
  esac
}
