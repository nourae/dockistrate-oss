#!/usr/bin/env bash

# Populate the dispatcher's local context without requiring bash-completion.
# COMP_WORDS splits ':' and '=' even inside image tags and --flag=value. Join
# those fragments only where the original line has no intervening whitespace.
__dockistrate_native_completion_context() {
  local raw_index=0 output_index=-1 token="" before="" separator=false previous_separator=false
  local remaining="${COMP_LINE:-}" cursor="${COMP_CWORD:-0}" adjacent=false
  words=()
  for ((raw_index = 0; raw_index < ${#COMP_WORDS[@]}; raw_index++)); do
    token="${COMP_WORDS[raw_index]}"
    separator=false
    case "$token" in
    '' | *[!:=]*) ;;
    *) separator=true ;;
    esac
    if [[ "$token" == *:* && "${COMP_WORDBREAKS:-=:}" != *:* ]]; then separator=false; fi
    if [[ "$token" == *=* && "${COMP_WORDBREAKS:-=:}" != *=* ]]; then separator=false; fi
    if [ -n "$token" ]; then
      before="${remaining%%"$token"*}"
    else
      # An empty current word may follow trailing whitespace. Matching an empty
      # pattern would discard that boundary and join it to a preceding ':'/'='.
      before="$remaining"
    fi
    adjacent=false
    if [ "$output_index" -gt 0 ] && [[ "$before" != *[[:space:]]* ]] &&
      { [ "$separator" = true ] || [ "$previous_separator" = true ]; }; then
      adjacent=true
    fi
    if [ "$adjacent" != true ]; then output_index=$((output_index + 1)); fi
    words[output_index]="${words[output_index]:-}${token}"
    if [ "$raw_index" -eq "$cursor" ]; then cword="$output_index"; fi
    remaining="${remaining#*"$token"}"
    previous_separator="$separator"
  done
  cur="${words[$cword]:-}"
  prev=""
  if [ "$cword" -gt 0 ]; then prev="${words[$((cword - 1))]:-}"; fi
}

# Readline replaces only the fragment after its word break, even though our
# handlers match the reconstructed value. Avoid nginx:nginx:latest or doubled
# --scope= prefixes in the inserted result. This also applies with the optional
# bash-completion helper, whose -n context reconstruction leaves word breaks set.
__dockistrate_trim_wordbreak_reply() {
  local full="${1:-}" raw="${COMP_WORDS[${COMP_CWORD:-0}]:-}" prefix="" i=0
  case "$raw" in
  '' | *[!:=]*)
    [[ "$full" == *"$raw" ]] || return 0
    prefix="${full%"$raw"}"
    ;;
  *) prefix="$full" ;;
  esac
  case "$prefix" in *: | *=) ;; *) return 0 ;; esac
  for ((i = 0; i < ${#COMPREPLY[@]}; i++)); do
    case "${COMPREPLY[i]}" in "$prefix"*) COMPREPLY[i]="${COMPREPLY[i]#"$prefix"}" ;; esac
  done
}
