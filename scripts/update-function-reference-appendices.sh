#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

func_lines=()
sh_files=()
if command -v rg >/dev/null 2>&1; then
  while IFS= read -r line; do
    func_lines+=("$line")
  done < <(rg -n '^function [A-Za-z0-9_]+\(' lib dockistrate.sh || true)
  sh_files+=("dockistrate.sh")
  while IFS= read -r line; do
    sh_files+=("$line")
  done < <(rg --files -g '*.sh' lib)
else
  while IFS= read -r line; do
    func_lines+=("$line")
  done < <(grep -R -n -E '^function[[:space:]]+[A-Za-z0-9_]+[[:space:]]*[(]' lib dockistrate.sh || true)
  sh_files+=("dockistrate.sh")
  while IFS= read -r line; do
    sh_files+=("$line")
  done < <(find lib -type f -name '*.sh')
fi

tmp_dir="$(mktemp -d)"
output_file=""
cleanup() {
  rm -rf "$tmp_dir"
  [ -z "$output_file" ] || rm -f "$output_file"
}
trap cleanup EXIT

func_list="$tmp_dir/functions.txt"
printf '%s\n' "${func_lines[@]}" | awk '
  /function[[:space:]]+[A-Za-z0-9_]+[[:space:]]*[(]/ {
    line=$0
    sub(/^.*function[[:space:]]+/, "", line)
    sub(/[[:space:]]*[(].*$/, "", line)
    print line
  }
' | awk '!seen[$0]++' >"$func_list"

if [ ! -s "$func_list" ]; then
  echo "[Error] No functions found for call graph generation." >&2
  exit 1
fi

cmd_map_file="$tmp_dir/cmd_map.tsv"
awk -v func_list="$func_list" '
  BEGIN {
    while ((getline < func_list) > 0) funcs[$1]=1
    close(func_list)
  }
  /^[[:space:]]*[a-z0-9-]+[)]/ {
    cmd=$0
    sub(/^[[:space:]]*/, "", cmd)
    sub(/[)].*$/, "", cmd)
    handler=""
  }
  cmd != "" {
    rest=$0
    sub(/^[^)]*[)][[:space:]]*/, "", rest)
    sub(/#.*/, "", rest)
    sub(/[[:space:]]*;;.*$/, "", rest)
    n=split(rest, parts, /[[:space:]]+/)
    # A multiline dispatch may load definitions before calling its handler.
    # Keep the final known function in the case body, ignoring shell keywords.
    for (i=1; i<=n; i++) {
      if (parts[i] in funcs) handler=parts[i]
    }
    if ($0 ~ /;;[[:space:]]*$/) {
      if (handler != "") print cmd "\t" handler
      cmd=""
    }
  }
' \
  lib/cli/run_command.sh >"$cmd_map_file"

calls_file="$tmp_dir/calls.tsv"
awk -v func_list="$func_list" '
  BEGIN {
    while ((getline < func_list) > 0) {
      funcs[$1]=1
      order[++n]=$1
    }
    close(func_list)
  }
  function record_call(fn, name, key) {
    key = fn SUBSEP name
    if (!seen[key]) {
      seen[key]=1
      calls[fn]=calls[fn] name " "
    }
  }
  function strip_strings_comments(line,   i,c,out,in_s,in_d,esc) {
    out=""
    in_s=0
    in_d=0
    esc=0
    for (i=1; i<=length(line); i++) {
      c=substr(line,i,1)
      if (in_s) {
        if (c=="'\''") in_s=0
        out=out " "
        continue
      }
      if (in_d) {
        if (esc) {
          esc=0
          out=out " "
          continue
        }
        if (c=="\\") {
          esc=1
          out=out " "
          continue
        }
        if (c=="\"") {
          in_d=0
          out=out " "
          continue
        }
        out=out " "
        continue
      }
      if (c=="'\''") { in_s=1; out=out " "; continue }
      if (c=="\"") { in_d=1; out=out " "; continue }
      if (c=="#") { out=out " "; break }
      out=out c
    }
    return out
  }
  function process_line(line, fn,   clean, arr, i, tok, n, expect) {
    clean = strip_strings_comments(line)
    gsub(/&&/, " && ", clean)
    gsub(/[|][|]/, " || ", clean)
    gsub(/[;|(){}!]/, " & ", clean)
    n = split(clean, arr, /[[:space:]]+/)
    expect = 1
    for (i=1; i<=n; i++) {
      tok = arr[i]
      if (tok == "") continue
      if (tok=="&&" || tok=="||" || tok=="|" || tok==";" || tok=="(" || tok==")" || tok=="{" || tok=="}" || tok=="!") { expect=1; continue }
      if (tok=="if" || tok=="while" || tok=="until" || tok=="then" || tok=="do" || tok=="elif" || tok=="else" || tok=="fi" || tok=="done" || tok=="esac" || tok=="case" || tok=="select" || tok=="in") { expect=1; continue }
      if (expect) {
        if (tok ~ /^[A-Za-z_][A-Za-z0-9_]*=.*/) { continue }
        if (tok=="sudo" || tok=="env" || tok=="command" || tok=="builtin" || tok=="time") { expect=1; continue }
        if (tok=="local" || tok=="declare" || tok=="typeset" || tok=="export" || tok=="readonly" || tok=="unset" || tok=="return" || tok=="exit" || tok=="break" || tok=="continue" || tok=="shift" || tok=="trap") { expect=0; continue }
        if (tok in funcs) { record_call(fn, tok) }
        expect=0
        continue
      }
    }
  }
  {
    line=$0
    if (in_heredoc) {
      test=line
      if (strip_tabs) sub(/^\t+/, "", test)
      if (test == heredoc_end) {
        in_heredoc=0
      }
      next
    }
    if (line ~ /^[[:space:]]*function[[:space:]]+[A-Za-z0-9_]+[[:space:]]*[(]/) {
      current_fn=line
      sub(/^[[:space:]]*function[[:space:]]+/, "", current_fn)
      sub(/[[:space:]]*[(].*$/, "", current_fn)
      next
    }
    if (match(line, /<<-?[[:space:]]*['\''"]?[A-Za-z0-9_]+['\''"]?/)) {
      heredoc=substr(line, RSTART, RLENGTH)
      sub(/^<<-?[[:space:]]*/, "", heredoc)
      gsub(/['\''"]/, "", heredoc)
      heredoc_end=heredoc
      strip_tabs = (index(line, "<<-") > 0)
      pre=substr(line,1,RSTART-1)
      if (current_fn != "") process_line(pre, current_fn)
      in_heredoc=1
      next
    }
    if (current_fn != "") process_line(line, current_fn)
  }
  END {
    for (i=1; i<=n; i++) {
      fn=order[i]
      calls_str=calls[fn]
      sub(/[[:space:]]+$/, "", calls_str)
      print fn "\t" calls_str
    }
  }
' "${sh_files[@]}" >"$calls_file"

before_file="$tmp_dir/before.md"
awk '/^## Appendix: Command Call Graphs/ {exit} {print}' docs/function-reference.md >"$before_file"

sections_file="$tmp_dir/sections.tsv"
awk '
  function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
  /^## Appendix: Command Call Graphs/ {in_section=1; next}
  /^## Appendix: Full Command Call Chains/ {exit}
  in_section && /^### / {section=substr($0,5); print "SECTION\t" section; next}
  in_section && /^- / {
    line=substr($0,3)
    split(line, a, "->")
    cmd=trim(a[1])
    print "ENTRY\t" section "\t" cmd
  }
' docs/function-reference.md >"$sections_file"

appendix_file="$tmp_dir/appendices.md"
awk -v calls_file="$calls_file" -v cmd_map_file="$cmd_map_file" -v sections_file="$sections_file" '
  function parse_commands(group, arr,   parts, n, i, c) {
    n = split(group, parts, /`/)
    c = 0
    for (i=2; i<=n; i+=2) {
      if (parts[i] != "") arr[++c] = parts[i]
    }
    return c
  }
  function direct_chain(handler,   list, arr, n, i, out) {
    list = calls_map[handler]
    n = split(list, arr, /[[:space:]]+/)
    out = ""
    for (i=1; i<=n; i++) {
      if (arr[i] == "") continue
      out = out " -> [" arr[i] "](#fn-" arr[i] ")"
    }
    return out
  }
  function transitive_chain(handler,   qh, qt, queue, visited, list, arr, n, i, fn, out) {
    delete visited
    delete queue
    qh = 1
    qt = 0
    out = ""
    list = calls_map[handler]
    n = split(list, arr, /[[:space:]]+/)
    for (i=1; i<=n; i++) if (arr[i] != "") queue[++qt] = arr[i]
    while (qh <= qt) {
      fn = queue[qh++]
      if (fn == "" || visited[fn]) continue
      visited[fn] = 1
      if (fn != handler && fn != "run_command" && fn != "audit_log") {
        out = out " -> [" fn "](#fn-" fn ")"
      }
      list = calls_map[fn]
      n = split(list, arr, /[[:space:]]+/)
      for (i=1; i<=n; i++) if (arr[i] != "") queue[++qt] = arr[i]
    }
    return out
  }
  function command_skips_audit(cmd) {
    return (cmd == "help" || cmd == "help-update" || cmd == "upgrade-preflight" || cmd == "fix-permissions" || cmd == "restore-backup")
  }
  function audit_segment(cmd) {
    return command_skips_audit(cmd) ? "" : " -> [audit_log](#fn-audit_log)"
  }
  function group_audit_segment(cmds, cmd_count,   i) {
    for (i=1; i<=cmd_count; i++) {
      if (!command_skips_audit(cmds[i])) {
        return " -> [audit_log](#fn-audit_log)"
      }
    }
    return ""
  }
  function emit_group(cmd_group, transitive,   cmds, cmd_count, i, cmd, handler, first, same, line) {
    cmd_count = parse_commands(cmd_group, cmds)
    if (cmd_count == 0) return
    first = ""
    same = 1
    for (i=1; i<=cmd_count; i++) {
      cmd = cmds[i]
      handler = cmd_map[cmd]
      if (handler == "") continue
      if (first == "") first = handler
      else if (handler != first) same = 0
    }
    if (first == "") return
    if (same) {
      line = cmd_group " -> [run_command](#fn-run_command)" group_audit_segment(cmds, cmd_count) " -> [" first "](#fn-" first ")"
      line = line (transitive ? transitive_chain(first) : direct_chain(first))
      print "- " line
      return
    }
    for (i=1; i<=cmd_count; i++) {
      cmd = cmds[i]
      handler = cmd_map[cmd]
      if (handler == "") continue
      line = "`" cmd "` -> [run_command](#fn-run_command)" audit_segment(cmd) " -> [" handler "](#fn-" handler ")"
      line = line (transitive ? transitive_chain(handler) : direct_chain(handler))
      print "- " line
    }
  }
  BEGIN {
    while ((getline < calls_file) > 0) {
      split($0, a, "\t")
      calls_map[a[1]] = a[2]
    }
    close(calls_file)
    while ((getline < cmd_map_file) > 0) {
      split($0, a, "\t")
      cmd_map[a[1]] = a[2]
    }
    close(cmd_map_file)
    while ((getline < sections_file) > 0) {
      split($0, a, "\t")
      if (a[1] == "SECTION") {
        section_order[++sc] = a[2]
        entry_count[a[2]] = 0
      } else if (a[1] == "ENTRY") {
        entry_count[a[2]]++
        entries[a[2], entry_count[a[2]]] = a[3]
      }
    }
    close(sections_file)
    print "## Appendix: Command Call Graphs"
    print ""
    print "Notation: `command -> run_command -> function -> ...`. Function names are linked to their entries; the chain includes all direct calls from the handler in order of first appearance. Most commands call `audit_log`; pre-runtime update commands and permission repair skip it, while restore defers it until candidate validation inside its handler. Generated by `scripts/update-function-reference-appendices.sh` using best-effort static parsing."
    for (s=1; s<=sc; s++) {
      section = section_order[s]
      print ""
      print "### " section
      for (e=1; e<=entry_count[section]; e++) {
        emit_group(entries[section, e], 0)
      }
    }
    print ""
    print "## Appendix: Full Command Call Chains"
    print ""
    print "Notation: `command -> run_command -> optional audit_log -> handler -> transitive calls`. Transitive calls list unique repo-defined functions reachable from the handler in breadth-first order; conditional branches, dynamic dispatch, and source may not execute at runtime. If `recreate_nginx_container` appears through `update_nginx_config`, that path is conditional: `update_nginx_config` reloads when possible and recreates only when required (for example, port-binding or container-state changes). Generated by `scripts/update-function-reference-appendices.sh`."
    for (s=1; s<=sc; s++) {
      section = section_order[s]
      print ""
      print "### " section
      for (e=1; e<=entry_count[section]; e++) {
        emit_group(entries[section, e], 1)
      }
    }
  }
' >"$appendix_file"

# Supply source destinations for links without a detailed manual entry. Keep the
# catalog in the replaceable region so regeneration cannot accumulate old anchors.
locations_file="$tmp_dir/locations.tsv"
printf '%s\n' "${func_lines[@]}" | awk -F: '
  {
    name=$0
    sub(/^.*function[[:space:]]+/, "", name)
    sub(/[[:space:]]*[(].*$/, "", name)
    print name "\t" $1 "\t" $2
  }
' >"$locations_file"

catalog_entries="$tmp_dir/catalog-entries.tsv"
awk -v locations_file="$locations_file" -v before_file="$before_file" '
  function scan_prose(line,   trimmed, run, rest, start, size, spaces, i) {
    trimmed=line
    sub(/^ ? ? ?/, "", trimmed)
    if (match(trimmed, /^```+|^~~~+/)) {
      run=substr(trimmed, RSTART, RLENGTH)
      rest=substr(trimmed, RLENGTH + 1)
      if (fence == "") {
        fence=run
        return ""
      }
      if (substr(run, 1, 1) == substr(fence, 1, 1) && length(run) >= length(fence) && rest ~ /^[[:space:]]*$/) {
        fence=""
        return ""
      }
    }
    if (fence != "") return ""
    # Keep brackets and destinations around code labels, but mask literal
    # links and anchor examples contained entirely inside inline code.
    while (match(line, /`[^`]*`/)) {
      start=RSTART
      size=RLENGTH
      spaces=""
      for (i=0; i<size; i++) spaces=spaces " "
      line=substr(line, 1, start - 1) spaces substr(line, start + size)
    }
    return line
  }
  BEGIN {
    while ((getline < locations_file) > 0) {
      split($0, fields, "\t")
      locations[fields[1]]=fields[2] "\t" fields[3]
      definitions[fields[1]]++
    }
    close(locations_file)
  }
  FNR == 1 { fence="" }
  {
    line=scan_prose($0)
    if (FILENAME == before_file) {
      anchor_line=line
      while (match(anchor_line, /<a[[:space:]][^>]*(id|name)=["\047]fn-[A-Za-z0-9_]+["\047]/)) {
        anchor=substr(anchor_line, RSTART, RLENGTH)
        sub(/^.*(id|name)=["\047]fn-/, "", anchor)
        sub(/["\047]$/, "", anchor)
        anchors[anchor]=1
        anchor_line=substr(anchor_line, RSTART + RLENGTH)
      }
    }
    while (match(line, /\]\(#fn-[A-Za-z0-9_]+\)/)) {
      name=substr(line, RSTART + 6, RLENGTH - 7)
      needed[name]=1
      line=substr(line, RSTART + RLENGTH)
    }
  }
  END {
    for (name in needed) {
      if (name in anchors) continue
      if (definitions[name] != 1) {
        print "[Error] Expected one source declaration for linked function " name "; found " (definitions[name] + 0) "." > "/dev/stderr"
        invalid=1
      } else {
        print name "\t" locations[name]
      }
    }
    if (invalid) exit 1
  }
' "$before_file" "$appendix_file" | LC_ALL=C sort >"$catalog_entries"

catalog_file="$tmp_dir/catalog.md"
awk -F '\t' '
  BEGIN {
    print ""
    print "## Linked function sources"
    print ""
    print "Functions without a detailed entry above link here to their source declarations. File paths and line numbers are generated with the call graphs; regenerate this reference after moving a declaration."
  }
  {
    print ""
    print "<a id=\"fn-" $1 "\"></a>"
    print ""
    print "- `" $1 "` — [" $2 ":" $3 "](../" $2 "#L" $3 ")"
  }
' "$catalog_entries" >"$catalog_file"

# Publish only after every linked helper has a unique source destination.
output_file="$(mktemp docs/.function-reference.XXXXXX)"
cat "$before_file" "$appendix_file" "$catalog_file" >"$output_file"
chmod 644 "$output_file"
mv "$output_file" docs/function-reference.md
output_file=""
echo "[Info] Updated docs/function-reference.md appendices and linked function sources."
