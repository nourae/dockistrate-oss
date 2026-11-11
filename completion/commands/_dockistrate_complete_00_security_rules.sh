#!/usr/bin/env bash
# Completion context is dynamically scoped; compgen results are completion words.
# shellcheck disable=SC2154,SC2207

# Complete options only outside condition tuples. A tuple's literal value may
# itself be --action or --domain and must not alter completion's parser state.
_dockistrate_complete_security_rules() {
  local command="$1" index=0 word="" option="" count="" flags=""
  case "$command" in
  list-security-rules)
    COMPREPLY=()
    if [ "$cword" -eq 2 ]; then
      COMPREPLY=($(compgen -W "$(__dockistrate_acl_domains)" -- "$cur"))
    fi
    return 0
    ;;
  add-security-rule)
    if [ "$cword" -eq 2 ]; then
      COMPREPLY=($(compgen -W "$(__dockistrate_acl_domains)" -- "$cur")); return 0
    fi
    if [ "$cword" -eq 3 ]; then
      COMPREPLY=($(compgen -W '1 2 3 4 5 6 7 8 9 10' -- "$cur")); return 0
    fi
    index=4; flags='--action --mode --code --reason --loc'
    ;;
  update-security-rule) index=3; flags='--domain --action --mode --code --reason --loc --count' ;;
  *) return 1 ;;
  esac
  COMPREPLY=()
  while [ "$index" -lt "$cword" ]; do
    word="${words[index]:-}"
    case "$word" in
    --domain | --action | --mode | --code | --reason | --loc | --count)
      option="$word"
      if [ "$((index + 1))" -eq "$cword" ]; then
        case "$option" in
        --action) COMPREPLY=($(compgen -W 'require block allow' -- "$cur")) ;;
        --mode) COMPREPLY=($(compgen -W 'and or' -- "$cur")) ;;
        --domain) COMPREPLY=($(compgen -W "$(__dockistrate_acl_domains)" -- "$cur")) ;;
        --count) COMPREPLY=($(compgen -W '1 2 3 4 5 6 7 8 9 10' -- "$cur")) ;;
        esac
        return 0
      fi
      index=$((index + 2))
      if [ "$option" = --count ] && [ "$command" = update-security-rule ]; then
        count="${words[index - 1]:-}"
        [[ "$count" =~ ^(10|[1-9])$ ]] || return 0
        index=$((index + count * 4))
      fi
      ;;
    *)
      [ "$command" = add-security-rule ] || return 0
      index=$((index + 4))
      ;;
    esac
  done
  [ "$index" -eq "$cword" ] || return 0
  case "$cur" in '' | --*) COMPREPLY=($(compgen -W "$flags" -- "$cur")) ;; esac
  return 0
}

__dockistrate_completion_handlers+=(_dockistrate_complete_security_rules)
