#!/usr/bin/env bash

function transaction_is_active() { return 1; }
function begin_transaction() { :; }

function _config_begin_runtime_prep_lock_if_needed() {
  local started_var="${1:-}"
  printf -v "$started_var" '%s' false
}

function _config_end_runtime_prep_lock_if_started() { :; }
