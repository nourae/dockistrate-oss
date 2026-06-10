#!/usr/bin/env bash

_shunit_mktempDir() {
  # Try the standard `mktemp` function.
  (exec mktemp -dqt shunit.XXXXXX 2>/dev/null) && return

  # The standard `mktemp` didn't work. Use our own.
  # shellcheck disable=SC2039
  if command [ -r '/dev/urandom' -a -x '/usr/bin/od' ]; then
    _shunit_random_=$(/usr/bin/od -vAn -N4 -tx4 </dev/urandom |
      command sed 's/^[^0-9a-f]*//')
  elif command [ -n "${RANDOM:-}" ]; then
    # $RANDOM works
    _shunit_random_=${RANDOM}${RANDOM}${RANDOM}$$
  else
    # `$RANDOM` doesn't work.
    _shunit_date_=$(date '+%Y%m%d%H%M%S')
    _shunit_random_=$(expr "${_shunit_date_}" / $$)
  fi

  _shunit_tmpDir_="${TMPDIR:-/tmp}/shunit.${_shunit_random_}"
  (umask 077 && command mkdir "${_shunit_tmpDir_}") ||
    _shunit_fatal 'could not create temporary directory! exiting'

  echo "${_shunit_tmpDir_}"
  unset _shunit_date_ _shunit_random_ _shunit_tmpDir_
}
