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
  function format_inline(s,   out, code, link, first, code_end, mid, end, text, url) {
    out = ""
    while (s != "") {
      code = index(s, "`")
      link = index(s, "[")
      first = code
      if (first == 0 || (link > 0 && link < first)) first = link
      if (first == 0) return out escape_html(s)
      out = out escape_html(substr(s, 1, first - 1))
      s = substr(s, first)
      if (substr(s, 1, 1) == "`") {
        code_end = index(substr(s, 2), "`")
        if (code_end > 0) {
          out = out "<code>" escape_html(substr(s, 2, code_end - 1)) "</code>"
          s = substr(s, code_end + 2)
          continue
        }
      } else {
        mid = index(s, "](")
        if (mid > 0) {
          end = index(substr(s, mid + 2), ")")
          if (end > 0) {
            text = substr(s, 2, mid - 2)
            url = substr(s, mid + 2, end - 1)
            # Parse label code spans inside the link, instead of splitting the
            # entire link at its backticks and losing its destination.
            out = out "<a href=\"" escape_html(url) "\">" format_inline(text) "</a>"
            s = substr(s, mid + end + 2)
            continue
          }
        }
      }
      # Unclosed code spans or links remain literal text.
      out = out escape_html(substr(s, 1, 1))
      s = substr(s, 2)
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
    fence_line = line
    sub(/^ ? ? ?/, "", fence_line)
    if (match(fence_line, /^```+|^~~~+/)) {
      fence_run = substr(fence_line, RSTART, RLENGTH)
      fence_rest = substr(fence_line, RLENGTH + 1)
      if (fence == "") {
        close_lists()
        print "<pre><code>"
        fence = fence_run
        next
      }
      if (substr(fence_run, 1, 1) == substr(fence, 1, 1) && length(fence_run) >= length(fence) && fence_rest ~ /^[[:space:]]*$/) {
        print "</code></pre>"
        fence = ""
        next
      }
    }
    if (fence != "") {
      print escape_html(line)
      next
    }
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
    if (fence != "") print "</code></pre>"
    close_lists()
    print "</body>"
    print "</html>"
  }
' "$input" >"$output"

echo "[Info] Wrote $output"
