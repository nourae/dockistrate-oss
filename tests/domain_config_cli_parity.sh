#!/usr/bin/env bash
# Shared fixture variables are consumed by sourced production modules.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in \
  utils/csv cli/common cli/arg_metadata cli/arg_option_hint cli/is_back_input \
  cli/get_arg_spec cli/get_arg_choices cli/arg_choices_misc cli/arg_choices_domain_config \
  cli/prompt_args_handlers_postprocess cli/review_command cli/review_domain_config cli/prompt_args_for_command \
  cli/interactive_picker_menu_data cli/interactive_picker; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/${module}.sh"
done

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-domain-cli.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

INTERACTIVE=true
READ_QUEUE=()
CHOICE_QUEUE=()
READ_CURSOR=0
CHOICE_CURSOR=0
REVIEW_COUNT=0
MOCK_DOMAIN_ACTIVE=false
MOCK_PENDING=false
MOCK_PREVIEW_FAIL=false
MOCK_APPLY_CALLS=0
PENDING_CHOICE_QUEUE=()
PENDING_CURSOR=0

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  exit 1
}

function domain_config_list() {
  [ "${1:-}" = all ] || fail_test 'Domain selection should include active and draft domains.'
  printf '%s\n' alpha.example.com broken.example.com
}

function domain_config_status() {
  case "$1" in
  alpha.example.com) printf '%s\n' 'pending changes' ;;
  broken.example.com) return 1 ;;
  esac
}

function domain_config_active() { [ "$MOCK_DOMAIN_ACTIVE" = true ]; }
function _domain_config_command_mutates() {
  case "$1" in apply-domain-config | migrate-state | init-domain-config | validate-domain-config) return 1 ;; esac
}
function _domain_config_command_guard() {
  unset DOMAIN_CONFIG_PENDING_DOMAIN
  if [ "$MOCK_PENDING" = true ]; then
    DOMAIN_CONFIG_PENDING_DOMAIN=alpha.example.com
    return 1
  fi
}
function apply_domain_config() {
  printf '%s\n' "$*" >>"$tmp_dir/apply-calls"
  if [ "${2:-}" = --dry-run ]; then
    printf 'Validated candidate summary for %s\n' "$1"
    [ "$MOCK_PREVIEW_FAIL" = false ] || return 1
  else
    MOCK_APPLY_CALLS=$((MOCK_APPLY_CALLS + 1))
    MOCK_PENDING=false
  fi
}
function migrate_state() { printf 'Validated migration summary: %s\n' "$*"; }

function dockistrate_prepare_runtime() { fail_test 'Prompting must not prepare live state.'; }
function prompt_args_handle_headers() { return 2; }
function prompt_args_handle_security_specials() { return 2; }
function cmd_requires_existing_backend() { return 1; }
function no_domain_overrides_message() { return 1; }
function mark_current_option() { :; }
function prompt_args_compute_default() { printf '%s' "${3:-}"; }
function _review_command_format_prompt() { _review_command_format_arg_summary "$@"; }
function choose_option_with_context_status() {
  if [ "$3" = domain-config-pending ]; then
    [ "$PENDING_CURSOR" -lt "${#PENDING_CHOICE_QUEUE[@]}" ] || fail_test 'Pending-edit choice queue exhausted.'
    printf -v "$1" '%s' 0
    printf -v "$2" '%s' "${PENDING_CHOICE_QUEUE[$PENDING_CURSOR]}"
    PENDING_CURSOR=$((PENDING_CURSOR + 1))
    return 0
  fi
  REVIEW_COUNT=$((REVIEW_COUNT + 1))
  printf -v "$1" '%s' 0
  printf -v "$2" '%s' 0
}

function choose_option() {
  [ "$CHOICE_CURSOR" -lt "${#CHOICE_QUEUE[@]}" ] || fail_test 'Choice queue exhausted.'
  local response="${CHOICE_QUEUE[$CHOICE_CURSOR]}"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  [ "$response" != cancel ] || return 1
  printf -v "$1" '%s' "$response"
}

function read_with_editing() {
  [ "$READ_CURSOR" -lt "${#READ_QUEUE[@]}" ] || fail_test 'Input queue exhausted.'
  local response="${READ_QUEUE[$READ_CURSOR]}"
  READ_CURSOR=$((READ_CURSOR + 1))
  printf -v "$2" '%s' "$response"
}

function run_prompt() {
  READ_CURSOR=0
  CHOICE_CURSOR=0
  REVIEW_COUNT=0
  if ! prompt_args_for_command "$1" >"$tmp_dir/prompt.out" 2>&1; then
    cat "$tmp_dir/prompt.out" >&2
    fail_test "Prompt failed for $1."
  fi
  [ "$SELECTED_CMD" = "$1" ] || fail_test 'Wrong selected command.'
}

function assert_args() {
  [ "${#SELECTED_ARGS[@]}" -eq "$#" ] || fail_test "Argument count mismatch: ${SELECTED_ARGS[*]:-}."
  local expected="" index=0
  for expected in "$@"; do
    [ "${SELECTED_ARGS[$index]}" = "$expected" ] || fail_test "Argument $index differs from <$expected>."
    index=$((index + 1))
  done
}

READ_QUEUE=(new.example.com)
CHOICE_QUEUE=(2)
run_prompt init-domain-config
assert_args new.example.com --kind dedicated
[ "$REVIEW_COUNT" -eq 1 ] || fail_test 'Template creation should use the ordinary review step.'

READ_QUEUE=()
CHOICE_QUEUE=(1 0)
run_prompt apply-domain-config
assert_args alpha.example.com --dry-run
[ "$REVIEW_COUNT" -eq 0 ] || fail_test 'Preview should not request mutation review.'

CHOICE_QUEUE=(0 1)
run_prompt apply-domain-config
assert_args --all
[ "$REVIEW_COUNT" -eq 1 ] || fail_test 'Applying all domains must use ordinary review.'
grep -q 'Validated candidate summary for --all' "$tmp_dir/prompt.out" || fail_test 'Apply review omitted the actual dry-run summary.'

CHOICE_QUEUE=(2)
run_prompt validate-domain-config
assert_args broken.example.com
[ "$REVIEW_COUNT" -eq 0 ] || fail_test 'Validation should not request mutation review.'

choices="$(get_arg_choices apply-domain-config domain_config_target)"
[[ "$choices" == *'alpha.example.com (pending changes)'* ]] || fail_test 'Pending draft must be visible.'
[[ "$choices" == *'broken.example.com (invalid draft)'* ]] || fail_test 'Invalid drafts must remain selectable.'

READ_QUEUE=('')
CHOICE_QUEUE=(1)
run_prompt migrate-state
assert_args
[ "$REVIEW_COUNT" -eq 1 ] || fail_test 'Migration apply must use ordinary review.'
grep -q 'Validated migration summary: --dry-run' "$tmp_dir/prompt.out" || fail_test 'Migration review omitted the conversion preview.'

READ_QUEUE=("$tmp_dir/backend details.csv")
CHOICE_QUEUE=(0)
run_prompt migrate-state
assert_args --dry-run --backend-details "$tmp_dir/backend details.csv"
[ "$REVIEW_COUNT" -eq 0 ] || fail_test 'Migration preview should not request mutation review.'

function __arg_choices_backup() { printf '%s\n' 'saved-backup.tar.gz|Saved backup'; }
READ_QUEUE=("$tmp_dir/backend details.csv")
CHOICE_QUEUE=(0)
run_prompt restore-backup
assert_args saved-backup.tar.gz --backend-details "$tmp_dir/backend details.csv"
[ "$REVIEW_COUNT" -eq 1 ] || fail_test 'Restoring with migration details must retain the ordinary review.'

# Pending drafts are resolved before executing an existing command. Applying
# them invalidates collected choices, while review/cancel never activates them.
MOCK_DOMAIN_ACTIVE=true
MOCK_PENDING=true
PENDING_CHOICE_QUEUE=(0 2)
PENDING_CURSOR=0
SELECTED_CMD=start-backend
SELECTED_ARGS=(alpha.example.com)
review_status=0
review_command_before_run start-backend alpha.example.com >"$tmp_dir/pending.out" 2>&1 || review_status=$?
[ "$review_status" -eq 1 ] && [ "$MOCK_APPLY_CALLS" -eq 0 ] || fail_test 'Review/cancel activated pending files.'
grep -q 'Validated candidate summary for alpha.example.com' "$tmp_dir/pending.out" || fail_test 'Pending review did not use the CLI preview.'
[ -z "$SELECTED_CMD" ] || fail_test 'Cancel retained a stale command selection.'

PENDING_CHOICE_QUEUE=(1)
PENDING_CURSOR=0
SELECTED_CMD=start-backend
SELECTED_ARGS=(alpha.example.com)
review_status=0
review_command_before_run start-backend alpha.example.com >"$tmp_dir/pending-apply.out" 2>&1 || review_status=$?
[ "$review_status" -eq 2 ] && [ "$MOCK_APPLY_CALLS" -eq 1 ] || fail_test 'Pending apply must recollect the original command arguments.'
[ -z "$SELECTED_CMD" ] && [ "${#SELECTED_ARGS[@]}" -eq 0 ] || fail_test 'Pending apply retained stale argument selections.'

MOCK_PREVIEW_FAIL=true
REVIEW_COUNT=0
review_status=0
review_command_before_run apply-domain-config alpha.example.com >"$tmp_dir/invalid-preview.out" 2>&1 || review_status=$?
[ "$review_status" -eq 1 ] && [ "$REVIEW_COUNT" -eq 0 ] || fail_test 'Invalid candidate reached mutation confirmation.'
MOCK_PREVIEW_FAIL=false
MOCK_DOMAIN_ACTIVE=false

READ_QUEUE=()
CHOICE_QUEUE=(cancel)
CHOICE_CURSOR=0
if prompt_args_for_command apply-domain-config >"$tmp_dir/cancel.out" 2>&1; then
  fail_test 'Cancel must stop selection.'
fi
[ -z "${SELECTED_CMD:-}" ] && [ "${#SELECTED_ARGS[@]}" -eq 0 ] || fail_test 'Cancel must clear the previous command.'

interactive_picker_commands_for_category 'Domain Configuration'
expected_commands='init-domain-config validate-domain-config apply-domain-config migrate-state'
[ "${INTERACTIVE_PICKER_CATEGORY_COMMANDS[*]}" = "$expected_commands" ] || fail_test 'Command browser is missing domain configuration actions.'
function interactive_picker_choose_command_list() {
  shift
  [ "$*" = "$expected_commands" ] || fail_test 'Home action differs from command browser.'
}
interactive_picker_run_home_action "$INTERACTIVE_PICKER_HOME_DOMAIN_CONFIG_LABEL"

__dockistrate_completion_handlers=()
# shellcheck source=../completion/commands/domain_config.sh
source "$ROOT_DIR/completion/commands/domain_config.sh"
cur=''
prev=apply-domain-config
cword=2
_dockistrate_complete_domain_config apply-domain-config
[ "${COMPREPLY[*]}" = '--all alpha.example.com broken.example.com' ] || fail_test 'Completion must include draft domains and --all.'
prev=--kind
cword=4
_dockistrate_complete_domain_config init-domain-config
[ "${COMPREPLY[*]}" = 'backend alias dedicated certificate-only' ] || fail_test 'Domain kind completion differs from the menu.'
prev=alpha.example.com
cword=3
_dockistrate_complete_domain_config apply-domain-config
[ "${COMPREPLY[*]}" = '--dry-run' ] || fail_test 'Apply completion must expose preview.'
cur='--'
prev=migrate-state
cword=2
_dockistrate_complete_domain_config migrate-state
[ "${COMPREPLY[*]}" = '--dry-run --backend-details' ] || fail_test 'Migration completion is incomplete.'
prev=saved-backup.tar.gz
cword=3
_dockistrate_complete_domain_config restore-backup
[ "${COMPREPLY[*]}" = '--backend-details' ] || fail_test 'Restore must complete legacy backend details.'

# Real discovery must work in a fresh completion shell without the application
# validators or the domain-list mocks used by the prompt tests above.
completion_state="$tmp_dir/completion-state"
mkdir -p "$completion_state/config" "$completion_state/domains/draft.example.com/config" \
  "$completion_state/domains/applied.example.com/runtime/applied" \
  "$completion_state/domains/applied.example.com/certs/custom-443" \
  "$completion_state/domains/applied.example.com/certs/retained-443" \
  "$completion_state/domains/UPPER.example.com/config" "$completion_state/domains/invalid_name/config"
printf '5\n' >"$completion_state/config/state_schema_version"
printf 'domain\napplied.example.com\nmissing.example.com\nUPPER.example.com\n' >"$completion_state/config/domain_inventory.csv"
printf 'schema_version,role,target\n5,certificate-only,\n' >"$completion_state/domains/applied.example.com/runtime/applied/domain.csv"
printf 'fixture\n' >"$completion_state/domains/applied.example.com/certs/custom-443/fullchain.pem"
printf 'fixture\n' >"$completion_state/domains/applied.example.com/certs/retained-443/fullchain.pem"
printf 'provider,port_suffix,source_ref,declared,specification,source_fullchain,source_privkey\n,,,no,,,\n' >"$completion_state/domains/applied.example.com/certs/retained-443/certificate.csv"
cat >"$tmp_dir/fresh-completion.sh" <<'FRESH_COMPLETION'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$1"
STATE_DIR="$2"
unset CONFIG_DIR
source "$ROOT_DIR/completion/dockistrate-completion.bash"
expected=$'applied.example.com\ndraft.example.com\nmissing.example.com'
[ "$(__dockistrate_domain_config_domains)" = "$expected" ]
__dockistrate_load_domain_config
[ "$(domain_config_list applied)" = $'applied.example.com\nmissing.example.com' ]
[ "$(domain_config_list draft)" = draft.example.com ]
domain_config_active
[ "$(__dockistrate_domain_certificate_refs)" = applied.example.com/custom-443 ]
cur=''
prev=apply-domain-config
cword=2
_dockistrate_complete_domain_config apply-domain-config
[ "${COMPREPLY[*]}" = '--all applied.example.com draft.example.com missing.example.com' ]
! declare -F is_valid_domain >/dev/null
! declare -F normalize_domain >/dev/null
[ "${CONFIG_DIR+x}" != x ]
[ ! -e "$STATE_DIR/config/backend_ports.csv" ]
[ ! -e "$STATE_DIR/domains/draft.example.com/runtime" ]
FRESH_COMPLETION
"$BASH" --noprofile --norc "$tmp_dir/fresh-completion.sh" "$ROOT_DIR" "$completion_state" ||
  fail_test 'Fresh-shell completion must discover domains without bootstrapping state.'

printf '%s\n' '[tests] domain_config_cli_parity.sh: PASS'
