#!/usr/bin/env bash

function transaction_return_failure() { return 1; }
function remove_backend_http_version() { :; }
function disable_backend_mtls() { :; }
function remove_backend_client_ip_header() { :; }
function remove_backend_proxy_ip_header() { :; }
function remove_backend_acl_policy() { :; }
function remove_backend_acl_status() { :; }
function remove_backend_security_rule_status() { :; }
