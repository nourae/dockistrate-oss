# shellcheck shell=bash

function check_openssl_installed() {
  if ! command -v openssl &>/dev/null; then
    echo "[Error] OpenSSL not installed." >&2
    if [ "$INTERACTIVE" = true ]; then
      read_with_editing "Install OpenSSL now? (y/n): " ans
      if [[ $ans =~ ^[Yy] ]]; then
        install_package openssl
        if ! command -v openssl &>/dev/null; then
          echo "[Error] OpenSSL install failed." >&2
          exit 1
        fi
        echo "[Info] OpenSSL installed."
      else
        echo "[Error] OpenSSL is required. Exiting." >&2
        exit 1
      fi
    else
      echo "[Error] OpenSSL is required. Exiting." >&2
      exit 1
    fi
  fi
}
