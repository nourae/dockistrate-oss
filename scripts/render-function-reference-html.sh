#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

input="docs/function-reference.md"
output="docs/function-reference.html"

awk '
  function escape_html(s) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;", s)
    gsub(/>/, "\\&gt;", s)
    return s
  }
  function format_links(s,   out, start, mid, end, pre, text, url) {
    out = ""
    while ((start = index(s, "[")) > 0) {
      mid = index(substr(s, start + 1), "](")
      if (mid == 0) break
      mid = start + mid
      end = index(substr(s, mid + 2), ")")
      if (end == 0) break
      end = mid + 1 + end
      pre = substr(s, 1, start - 1)
      text = substr(s, start + 1, mid - start - 1)
      url = substr(s, mid + 2, end - mid - 2)
      out = out pre "<a href=\"" url "\">" text "</a>"
      s = substr(s, end + 1)
    }
    return out s
  }
  function format_inline(s,   parts, n, i, seg, out) {
    n = split(s, parts, /`/)
    out = ""
    for (i = 1; i <= n; i++) {
      seg = parts[i]
      if (i % 2 == 0) {
        seg = escape_html(seg)
        out = out "<code>" seg "</code>"
      } else {
        seg = escape_html(seg)
        seg = format_links(seg)
        out = out seg
      }
    }
    return out
  }
  function close_lists(  t) {
    while (list_depth > 0) {
      t = list_type[list_depth]
      print "</" t ">"
      list_depth--
    }
  }
  function adjust_lists(target_depth, target_type,  t) {
    while (list_depth > target_depth) {
      t = list_type[list_depth]
      print "</" t ">"
      list_depth--
    }
    if (list_depth == target_depth && list_depth > 0 && list_type[list_depth] != target_type) {
      t = list_type[list_depth]
      print "</" t ">"
      list_type[list_depth] = target_type
      print "<" target_type ">"
    }
    while (list_depth < target_depth) {
      list_depth++
      list_type[list_depth] = target_type
      print "<" target_type ">"
    }
  }
  function leading_indent(s,  i, c, n) {
    n = 0
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c == " ") {
        n++
      } else if (c == "\t") {
        n += 2
      } else {
        break
      }
    }
    return n
  }
  BEGIN {
    list_depth = 0
    print "<!doctype html>"
    print "<html lang=\"en\">"
    print "<head>"
    print "<meta charset=\"utf-8\">"
    print "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    print "<title>Dockistrate Function Reference</title>"
    print "<style>"
    print "  :root { color-scheme: light; }"
    print "  body { margin: 32px auto; max-width: 1000px; padding: 0 24px 64px; font-family: \"Georgia\", \"Times New Roman\", serif; line-height: 1.55; color: #1f1f1f; background: #f7f4ef; }"
    print "  h1, h2, h3 { font-family: \"Trebuchet MS\", \"Verdana\", sans-serif; letter-spacing: 0.01em; }"
    print "  h1 { font-size: 2.2rem; margin: 1.2rem 0 0.8rem; }"
    print "  h2 { font-size: 1.6rem; margin: 2rem 0 0.6rem; }"
    print "  h3 { font-size: 1.2rem; margin: 1.2rem 0 0.4rem; }"
    print "  p { margin: 0.6rem 0; }"
    print "  ul, ol { margin: 0.4rem 0 0.8rem 1.2rem; }"
    print "  li { margin: 0.2rem 0; }"
    print "  code { font-family: \"Menlo\", \"Consolas\", \"Courier New\", monospace; background: #efe7dc; padding: 0 4px; border-radius: 4px; }"
    print "  a { color: #0a5b7f; text-decoration: none; }"
    print "  a:hover { text-decoration: underline; }"
    print "  hr { border: none; border-top: 1px solid #d6cbbf; margin: 2rem 0; }"
    print "</style>"
    print "</head>"
    print "<body>"
  }
  {
    line = $0
    if (index(line, "<a ") == 1 && index(line, "</a>") > 0) {
      close_lists()
      print line
      next
    }
    if (line ~ /^###[[:space:]]+/ || line ~ /^##[[:space:]]+/ || line ~ /^#[[:space:]]+/) {
      close_lists()
      if (line ~ /^###[[:space:]]+/) level = 3
      else if (line ~ /^##[[:space:]]+/) level = 2
      else level = 1
      gsub(/^[#]+[[:space:]]+/, "", line)
      if (level == 2) tag = "h2"
      else if (level == 3) tag = "h3"
      else tag = "h1"
      print "<" tag ">" format_inline(line) "</" tag ">"
      next
    }
    if (match(line, /^[[:space:]]*-[[:space:]]+/)) {
      indent = leading_indent(line)
      level = int(indent / 2) + 1
      adjust_lists(level, "ul")
      content = substr(line, RLENGTH + 1)
      print "<li>" format_inline(content) "</li>"
      next
    }
    if (match(line, /^[[:space:]]*[0-9]+\.[[:space:]]+/)) {
      indent = leading_indent(line)
      level = int(indent / 2) + 1
      adjust_lists(level, "ol")
      content = substr(line, RLENGTH + 1)
      print "<li>" format_inline(content) "</li>"
      next
    }
    if (line ~ /^[[:space:]]*$/) {
      next
    }
    close_lists()
    print "<p>" format_inline(line) "</p>"
  }
  END {
    close_lists()
    print "</body>"
    print "</html>"
  }
' "$input" >"$output"

echo "[Info] Wrote $output"
