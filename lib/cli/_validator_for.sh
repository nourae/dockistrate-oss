# shellcheck shell=bash

# Map interactive argument names to validators for immediate feedback
function _validator_for() {
  local cmd="$1" arg="$2"
  case "$arg" in
  domain)
    case "$cmd" in
    add-backend | add-cert | replace-cert) echo "is_valid_domain" ;;
    *) echo "domain_exists" ;;
    esac
    ;;
  image) echo "is_valid_image_ref" ;;
  nginx_image) echo "is_valid_image_ref" ;;
  certbot_image) echo "is_valid_image_ref" ;;
  container_port | nginx_port | listen | port) echo "is_valid_port" ;;
  port_suffix)
    case "$cmd" in
    add-cert | replace-cert) echo "is_valid_optional_port" ;;
    *) echo "is_valid_port" ;;
    esac
    ;;
  protocol) echo "is_valid_protocol" ;;
  cert_path) echo "is_existing_cert_dir" ;;
  ws | expose) echo "is_yes_no" ;;
  header) echo "is_valid_header_name" ;;
  header_or_off) echo "is_header_or_off" ;;
  on_off) echo "is_on_off" ;;
  true_or_false) echo "is_true_false" ;;
  version) echo "is_valid_http_version" ;;
  *) echo "" ;;
  esac
}
