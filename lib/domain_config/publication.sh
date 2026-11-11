# shellcheck shell=bash

# Historical source journals contain flat CSV inputs. Only explicit backup
# restore selects opaque draft trees; record that distinction for later recovery.
function _domain_config_source_layout() {
  local record="$1" layout="" extra=""
  if [ ! -e "$record/layout" ] && [ ! -L "$record/layout" ]; then printf 'flat\n'; return 0; fi
  [ -f "$record/layout" ] && [ ! -L "$record/layout" ] || return 1
  {
    IFS= read -r layout || return 1
    if IFS= read -r extra || [ -n "$extra" ]; then return 1; fi
  } <"$record/layout"
  case "$layout" in flat | tree) printf '%s\n' "$layout" ;; *) return 1 ;; esac
}

function _domain_config_source_fingerprint() {
  case "$1" in
  flat) _domain_config_input_fingerprint "$2" ;;
  tree) _domain_config_draft_tree_fingerprint "$2" ;;
  *) return 1 ;;
  esac
}

function _domain_config_source_copy() {
  case "$1" in
  flat) _domain_config_copy_inputs "$2" "$3" ;;
  tree) _domain_config_draft_tree_copy "$2" "$3" ;;
  *) return 1 ;;
  esac
}

function _domain_config_source_guard() {
  case "$1" in
  flat) _domain_config_dir_guard "$2" ;;
  tree) _domain_config_draft_tree_guard "$2" ;;
  *) return 1 ;;
  esac
}

function _domain_config_source_publish() {
  local domain="${1:-}" candidate="${2:-}" expected="${3:-}" layout="${4:-flat}" root="" destination="" journal="" present=no current=""
  case "$layout" in flat | tree) ;; *) return 1 ;; esac
  [ "$expected" != unpublishable ] || {
    _domain_config_error "Invalid configuration for $domain cannot be published; review its files before retrying."; return 1;
  }
  root="$(domain_config_root)"; destination="$root/$domain/config"
  _domain_config_validate_name "$domain" || return 1
  runtime_state_path_guard_if_declared "$destination" "editable configuration" || return 1
  current="$(_domain_config_source_fingerprint "$layout" "$destination")" || return 1
  [ "$current" = "$expected" ] || {
    _domain_config_error "Files changed during the command for $domain; preserving your edits."; return 1;
  }
  [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || return 1
  journal="$DOMAIN_CONFIG_RUNTIME_JOURNAL/sources/$domain"
  mkdir -p "$journal/before" "$journal/after" || return 1
  printf '%s\n' "$layout" >"$journal/layout" || return 1
  if [ -d "$destination" ]; then
    present=yes
    _domain_config_source_copy "$layout" "$destination" "$journal/before" || return 1
  fi
  printf '%s\n' "$present" >"$journal/was_present" || return 1
  if [ -n "$candidate" ]; then _domain_config_source_copy "$layout" "$candidate" "$journal/after" || return 1; fi
  printf '%s\n' "$([ -n "$candidate" ] && printf write || printf remove)" >"$journal/action" || return 1
  if [ -n "$candidate" ]; then _domain_config_source_copy "$layout" "$candidate" "$journal/publish" || return 1; fi
  current="$(_domain_config_source_fingerprint "$layout" "$destination")" || return 1
  [ "$current" = "$expected" ] || {
    _domain_config_error "Files changed while preparing publication for $domain; preserving your edits."; return 1;
  }
  # The recovery record is complete before the first editable-file mutation.
  printf 'publishing\n' >"$journal/phase" || return 1
  printf 'ready\n' >"$journal/ready" || return 1
  if [ -e "$destination" ]; then
    _domain_config_source_guard "$layout" "$destination" || return 1
    mv "$destination" "$journal/detached" || return 1
    current="$(_domain_config_source_fingerprint "$layout" "$journal/detached")" || return 1
    if [ "$current" != "$expected" ]; then
      mv "$journal/detached" "$destination" || return 1
      _domain_config_error "Files changed during publication for $domain; preserving your edits."; return 1
    fi
  fi
  if [ -n "$candidate" ]; then
    mkdir -p "${destination%/*}" || return 1
    mv "$journal/publish" "$destination" || return 1
  fi
  printf 'published\n' >"$journal/phase" || return 1
}

function _domain_config_source_verify() {
  local record="" domain="" destination="" action="" root="" original="" detached="" current="" published="" layout=""
  [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || return 0
  root="$(domain_config_root)"
  for record in "$DOMAIN_CONFIG_RUNTIME_JOURNAL"/sources/*; do
    [ -f "$record/ready" ] || continue
    layout="$(_domain_config_source_layout "$record")" || return 1
    domain="${record##*/}"; destination="$root/$domain/config"
    IFS= read -r action <"$record/action" || return 1
    if [ -e "$record/detached" ] || [ -L "$record/detached" ]; then
      original="$(_domain_config_source_fingerprint "$layout" "$record/before")" || return 1
      detached="$(_domain_config_source_fingerprint "$layout" "$record/detached")" || return 1
      if [ "$original" != "$detached" ]; then
        _domain_config_error "An editor changed the previous files for $domain during publication; preserving those edits and restoring the previous runtime."
        return 1
      fi
    fi
    if [ "$action" = write ]; then
      current="$(_domain_config_source_fingerprint "$layout" "$destination")" || return 1
      published="$(_domain_config_source_fingerprint "$layout" "$record/after")" || return 1
      [ "$current" = "$published" ] && continue
    else
      [ ! -e "$destination" ] && [ ! -L "$destination" ] && continue
    fi
    _domain_config_error "Files changed before commit for $domain; preserving your edits and restoring the previous runtime."
    return 1
  done
}

function domain_config_source_rollback() {
  local journal="${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" record="" domain="" destination="" action="" root="" layout=""
  local detached_changed=false destination_changed=false failed=false original="" detached="" current="" published="" phase="" was_present=""
  [ -n "$journal" ] || return 0
  root="$(domain_config_root)"
  for record in "$journal"/sources/*; do
    [ -f "$record/ready" ] || continue
    layout="$(_domain_config_source_layout "$record")" || return 1
    domain="${record##*/}"; _domain_config_validate_name "$domain" || return 1
    destination="$root/$domain/config"
    IFS= read -r action <"$record/action" || return 1
    IFS= read -r phase <"$record/phase" || return 1
    [ "$phase" != rolled_back ] || continue
    IFS= read -r was_present <"$record/was_present" || return 1
    detached_changed=false; destination_changed=false
    if [ -e "$record/detached" ] || [ -L "$record/detached" ]; then
      original="$(_domain_config_source_fingerprint "$layout" "$record/before")" || return 1
      detached="$(_domain_config_source_fingerprint "$layout" "$record/detached")" || return 1
      [ "$original" = "$detached" ] || detached_changed=true
    fi
    if [ "$action" = write ]; then
      # A subsequent editor write belongs to the operator and survives rollback.
      current="$(_domain_config_source_fingerprint "$layout" "$destination")" || return 1
      published="$(_domain_config_source_fingerprint "$layout" "$record/after")" || return 1
      if [ "$current" != "$published" ]; then
        if [ -e "$destination" ] || [ "$phase" != publishing ]; then destination_changed=true; fi
      fi
    else
      { [ ! -e "$destination" ] && [ ! -L "$destination" ]; } || destination_changed=true
    fi
    if [ "$destination_changed" = true ]; then
      if [ "$detached_changed" = true ]; then
        printf '[Error] Concurrent edits remain in both %s and %s; preserved both copies. Resolve these edits before retrying recovery.\n' "$destination" "$record/detached" >&2
        failed=true
      fi
      continue
    fi
    # Before the directory swap, the original is still live. Do not replace
    # its inode with a copied snapshot, even when the command changes no bytes.
    if [ "$phase" = publishing ] && [ "$was_present" = yes ] &&
      [ ! -e "$record/detached" ] && [ -d "$destination" ]; then
      continue
    fi
    if [ -d "$destination" ]; then
      _domain_config_source_guard "$layout" "$destination" || return 1
      rm -rf "$destination" || return 1
    fi
    if [ "$was_present" = yes ]; then
      if [ -d "$record/detached" ]; then
        _domain_config_source_guard "$layout" "$record/detached" || return 1
        # Restore the original inode so an editor holding its descriptor keeps
        # writing to the live draft after recovery as well.
        mv "$record/detached" "$destination" || return 1
      else
        _domain_config_source_copy "$layout" "$record/before" "$destination" || return 1
      fi
    fi
    printf 'rolled_back\n' >"$record/phase" || return 1
  done
  [ "$failed" = false ]
}

function _domain_config_command_snapshot() {
  local work="${1:-}" root="" domain=""
  root="$(domain_config_root)"
  mkdir -p "$work/source-fingerprints" || return 1
  domain_config_list all >"$work/before-domains" || return 1
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    # Unrelated drafts can contain invalid entries. Do not traverse those or
    # block a command that leaves them alone; publication still requires a
    # complete, valid fingerprint and explicitly refuses this marker.
    if ! _domain_config_input_fingerprint "$root/$domain/config" >"$work/source-fingerprints/$domain" 2>/dev/null; then
      printf 'unpublishable\n' >"$work/source-fingerprints/$domain" || return 1
    fi
  done <"$work/before-domains"
  _domain_config_adapter_fingerprint >"$work/adapter-fingerprint"
}

function _domain_config_adapter_fingerprint() {
  local name="" file="" root=""
  local -a files=()
  root="$(domain_config_root)"
  while IFS= read -r name; do
    [ ! -f "$CONFIG_DIR/$name" ] || files+=("$CONFIG_DIR/$name")
  done < <(_domain_config_cache_files)
  for file in "$root"/*/runtime/backend.csv "$root"/*/certs/*/certificate.csv; do
    [ ! -f "$file" ] || files+=("$file")
  done
  if [ "${#files[@]}" -gt 0 ]; then cksum "${files[@]}"; fi
}

function _domain_config_activate_deferred_render() {
  if [ "${DOMAIN_CONFIG_RENDER_REQUESTED:-false}" = true ]; then
    local BACKEND_IDENTITY_MIGRATION=false
    if [ "${DOMAIN_CONFIG_MUTATION_COMMAND:-}" = update-backend ] &&
      [ "${DOMAIN_CONFIG_BACKEND_IDENTITY_MIGRATION:-false}" = true ]; then
      BACKEND_IDENTITY_MIGRATION=true
    fi
    DOMAIN_CONFIG_DEFER_RENDER=false
    update_nginx_config || return 1
  fi
}

# Compilation coalesces identical case variants. An unrelated command must not
# mistake that derived view for an instruction to rewrite editable headers.
function _domain_config_preserve_header_sources() {
  local tree="$1" root="" path="" domain="" original="" exported="" old=""
  root="$(domain_config_root)" || return 1
  for path in "$tree"/*; do
    [ -d "$path" ] || continue
    domain="${path##*/}"; old="$root/$domain/runtime/applied/headers.csv"
    [ -f "$old" ] || continue
    original="$(_header_records "$old" domain "$domain" | LC_ALL=C sort)" || return 1
    exported="$(_header_records "$path/config/headers.csv" domain "$domain" | LC_ALL=C sort)" || return 1
    if [ "$original" = "$exported" ]; then cp -p "$old" "$path/config/headers.csv" || return 1; fi
  done
}

function _domain_config_sync_command() {
  local work="${1:-}" root="" domain="" path="" expected="" old="" identity_move=false
  root="$(domain_config_root)"
  case "${DOMAIN_CONFIG_MUTATION_COMMAND:-}" in
  move-security-rule | move-acl-rule) identity_move=true ;;
  esac
  # Global settings and operational commands do not rewrite domain sources.
  # Rule moves can change stable identities even when their contents match.
  if [ "${DOMAIN_CONFIG_TERMINAL_UNINSTALL:-false}" != true ] &&
    [ "$identity_move" = false ] && [ -f "$work/adapter-fingerprint" ] &&
    [ "$(_domain_config_adapter_fingerprint)" = "$(cat "$work/adapter-fingerprint")" ]; then
    _domain_config_activate_deferred_render
    return $?
  fi
  _domain_config_export_tree "$work/exported" || return 1
  _domain_config_preserve_header_sources "$work/exported" || return 1
  domain_config_validate_tree "$work/exported" || return 1
  _domain_config_activate_deferred_render || return 1
  : >"$work/changed"
  for path in "$work/exported"/*; do
    [ -d "$path" ] || continue
    domain="${path##*/}"; old="$root/$domain/runtime/applied"
    if _domain_config_same "$path/config" "$old"; then continue; fi
    if [ -d "$root/$domain/config" ] &&
      { ! domain_config_validate_source "$domain" "$root/$domain/config" >/dev/null 2>&1 ||
        ! _domain_config_same "$root/$domain/config" "$old"; }; then
      _domain_config_error "Pending file edits for $domain must be applied before this command."; return 1
    fi
    expected=missing
    [ ! -f "$work/source-fingerprints/$domain" ] || expected="$(cat "$work/source-fingerprints/$domain")"
    _domain_config_source_publish "$domain" "$path/config" "$expected" || return 1
    printf '%s\n' "$domain" >>"$work/changed"
  done
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    [ ! -d "$work/exported/$domain" ] || continue
    # Never remove an unapplied draft merely because it is absent from active state.
    if [ -d "$root/$domain/runtime/applied" ]; then
      { domain_config_validate_source "$domain" "$root/$domain/config" >/dev/null 2>&1 &&
        _domain_config_same "$root/$domain/config" "$root/$domain/runtime/applied"; } || {
        _domain_config_error "Pending file edits for $domain prevent its removal."; return 1;
      }
    else
      [ "${command:-}" = uninstall-all ] || continue
    fi
    expected="$(cat "$work/source-fingerprints/$domain")"
    _domain_config_source_publish "$domain" "" "$expected" || return 1
    for path in runtime generated; do
      runtime_state_path_guard_if_declared "$root/$domain/$path" "removed domain artifacts" || return 1
      rm -rf "$root/$domain/$path" || return 1
    done
  done <"$work/before-domains"
  if [ "${DOMAIN_CONFIG_TERMINAL_UNINSTALL:-false}" = true ]; then
    [ "${DOMAIN_CONFIG_MUTATION_COMMAND:-}" = uninstall-all ] &&
      [ ! -e "$CONFIG_DIR" ] && [ ! -L "$CONFIG_DIR" ] || return 1
    for path in "$work/exported"/*; do
      { [ ! -e "$path" ] && [ ! -L "$path" ]; } || {
        _domain_config_error 'Uninstall left active domain configuration; refusing to finish without its inventory.'
        return 1
      }
    done
    # Config/all scope deliberately removed this directory. Its empty export
    # has no applied inventory or cache marker to publish before commit.
    return 0
  fi
  _domain_config_publish_applied "$work/exported" "$work/changed"
}
