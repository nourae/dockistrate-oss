#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-completion-fresh.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/tool/state/config"
cp -R "$ROOT_DIR/completion" "$ROOT_DIR/lib" "$TEST_ROOT/tool/"
printf '#!/usr/bin/env bash\nexit 99\n' >"$TEST_ROOT/tool/dockistrate.sh"
printf '%s\n' 'record_type,domain,backend_upstream,network' 'backend,primary.example.com,127.0.0.1:80,dockistrate-net' >"$TEST_ROOT/tool/state/config/backend_ports.csv"
printf '%s\n' 'record_type,hostname,target_domain' 'alias,alias.example.com,primary.example.com' 'dedicated,dedicated.example.com,primary.example.com' >"$TEST_ROOT/tool/state/config/backend_aliases.csv"
mkdir -p "$TEST_ROOT/tool/state/domains/draft.example.com/config"
printf 'invalid draft\n' >"$TEST_ROOT/tool/state/domains/draft.example.com/config/domain.csv"
function fail_test() { echo "[Error] $*" >&2; exit 1; }
unset -f _get_comp_words_by_ref 2>/dev/null || true
STATE_DIR=caller-state BACKEND_PORTS_FILE=caller-path
# shellcheck disable=SC1091
source "$TEST_ROOT/tool/completion/dockistrate-completion.bash"
function complete_command() {
  COMP_WORDS=("$TEST_ROOT/tool/dockistrate.sh" "$1" "${2:-}")
  COMP_CWORD=2
  _dockistrate_complete
}
complete_command start-backend
[ "${COMPREPLY[*]-}" = primary.example.com ] || fail_test 'Fresh completion cannot find applied backends'
complete_command set-backend-hsts
[ "${COMPREPLY[*]-}" = 'alias.example.com dedicated.example.com primary.example.com' ] || fail_test 'Header completion omits host identities'
complete_command enable-backend-mtls
[ "${COMPREPLY[*]-}" = 'dedicated.example.com primary.example.com' ] || fail_test 'mTLS completion offered ineffective alias override'
complete_command start-backend nonexistent
[ "${#COMPREPLY[@]}" -eq 0 ] || fail_test 'Previous completion leaked into no-match result'
complete_command apply-domain-config
[ "${COMPREPLY[*]-}" = '--all draft.example.com' ] || fail_test 'Apply discovery hid an invalid draft'
[ "$STATE_DIR" = caller-state ] && [ "$BACKEND_PORTS_FILE" = caller-path ] || fail_test 'Completion changed caller globals'
[ "$(cat "$TEST_ROOT/tool/state/domains/draft.example.com/config/domain.csv")" = 'invalid draft' ] || fail_test 'Completion rewrote a draft'

# Native command discovery also works without bash-completion installed.
COMP_WORDS=(dockistrate.sh update-b)
COMP_CWORD=1
_dockistrate_complete
[[ " ${COMPREPLY[*]} " == *' update-backend '* ]] || fail_test 'Command completion missing'

# These arrays are Bash's actual completion context, captured in an interactive
# PTY with the default COMP_WORDBREAKS. The inserted suffix must not duplicate
# an image tag or flag prefix already present before the word break.
COMP_WORDS=(dockistrate.sh start-nginx --nginx-image nginx : la)
COMP_CWORD=5 COMP_LINE='dockistrate.sh start-nginx --nginx-image nginx:la'
_dockistrate_complete
[ "${COMPREPLY[*]-}" = 'latest latest' ] || fail_test 'Image-tag completion lost context or duplicated its prefix'
COMP_WORDS=(dockistrate.sh set-nginx-image nginx : latest '')
COMP_CWORD=5 COMP_LINE='dockistrate.sh set-nginx-image nginx:latest '
_dockistrate_complete
[ "${COMPREPLY[*]-}" = 'always if-missing never' ] || fail_test 'Image tag shifted pull-mode argument position'
COMP_WORDS=(dockistrate.sh uninstall-all --scope = co)
COMP_CWORD=4 COMP_LINE='dockistrate.sh uninstall-all --scope=co'
_dockistrate_complete
[ "${COMPREPLY[*]-}" = config ] || fail_test 'Equals-form scope completion lost or duplicated its prefix'
COMP_WORDS=(dockistrate.sh start-nginx --nginx-image nginx :)
COMP_CWORD=4 COMP_LINE='dockistrate.sh start-nginx --nginx-image nginx:'
_dockistrate_complete
[ "${COMPREPLY[*]-}" = 'latest latest' ] || fail_test 'Empty tag suffix completion duplicated the prefix'

# Whitespace still separates arguments, and an installed helper remains used.
COMP_WORDS=(dockistrate.sh set-nginx-image nginx : latest)
COMP_CWORD=4 COMP_LINE='dockistrate.sh set-nginx-image nginx : latest'
function verify_context() {
  local cur='' prev='' cword=0
  local -a words=()
  __dockistrate_native_completion_context
  [ "${#words[@]}" -eq 5 ] && [ "$prev" = : ] || fail_test 'Whitespace around a separator was discarded'
}
verify_context
# Bash may provide an empty current token after a separator. Whitespace after
# that separator starts a new argument; an empty suffix without whitespace does
# not. Keep both forms distinct for tags and equals-form options.
function verify_empty_separator_context() {
  local expected_cword="$1" expected_cur="$2" expected_prev="$3"
  local cur='' prev='' cword=0
  local -a words=()
  __dockistrate_native_completion_context
  [ "$cword" -eq "$expected_cword" ] && [ "$cur" = "$expected_cur" ] &&
    [ "$prev" = "$expected_prev" ] || fail_test "Empty suffix context changed for: $COMP_LINE"
}
COMP_WORDS=(dockistrate.sh set-nginx-image nginx : '')
COMP_CWORD=4 COMP_LINE='dockistrate.sh set-nginx-image nginx:'
verify_empty_separator_context 2 nginx: set-nginx-image
COMP_LINE='dockistrate.sh set-nginx-image nginx: '
verify_empty_separator_context 3 '' nginx:
_dockistrate_complete
[ "${COMPREPLY[*]-}" = 'always if-missing never' ] || fail_test 'Whitespace after an empty tag hid the next argument'
COMP_WORDS=(dockistrate.sh uninstall-all --scope = '')
COMP_CWORD=4 COMP_LINE='dockistrate.sh uninstall-all --scope='
verify_empty_separator_context 2 --scope= uninstall-all
COMP_LINE='dockistrate.sh uninstall-all --scope= '
verify_empty_separator_context 3 '' --scope=
helper_used=false
function _get_comp_words_by_ref() { helper_used=true; __dockistrate_native_completion_context; }
COMP_WORDS=(dockistrate.sh uninstall-all --scope = co)
COMP_CWORD=4 COMP_LINE='dockistrate.sh uninstall-all --scope=co'
_dockistrate_complete
[ "$helper_used" = true ] && [ "${COMPREPLY[*]-}" = config ] || fail_test 'Installed context helper path changed'
echo '[tests] completion_fresh_shell.sh: PASS'
