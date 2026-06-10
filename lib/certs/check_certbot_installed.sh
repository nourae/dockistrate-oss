# shellcheck shell=bash

function check_certbot_installed() {
  # Using the certbot Docker image means we don't need a host certbot installation.
  return 0
}
