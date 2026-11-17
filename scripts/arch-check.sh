#!/usr/bin/env bash
# Architecture checks (ROADMAP §N0). Fails, listing every violation, when any
# Swift target:
#   no-webkit      imports WebKit/SafariServices/JavaScriptCore or names a web-view type;
#   no-process     can spawn a process (Process, NSTask, posix_spawn, system(), fork/exec,
#                  popen, AppleScript/OSAScript/user script tasks, NSWorkspace);
#   pure-packages  imports SwiftUI/AppKit/UIKit/Cocoa from a pure package;
#   get-only       builds a non-GET request in the adapters (any method literal other than
#                  the one `httpMethod = "GET"`, a body, an upload, or a request/session
#                  constructed outside the bounded transport);
#   inert-text     interprets markup (AttributedString(markdown:), HTML/RTF documents).
# Comments are stripped first (string-aware), so a comment can neither trigger nor hide
# a violation. Usage:
#   scripts/arch-check.sh [ROOT]                 # source rules
#   scripts/arch-check.sh --binaries BIN_DIR     # linked-framework rule on built products
# Bash 3.2-compatible (the macOS runners' /bin/bash).
set -euo pipefail

if [ "${1:-}" = "--binaries" ]; then
  dir="${2:?usage: arch-check.sh --binaries BIN_DIR}"
  bad=0
  found=0
  for bin in "$dir"/NativeWorkspace "$dir"/nw-replay "$dir"/nw-fixture-server; do
    [ -f "$bin" ] || continue
    found=$((found + 1))
    if otool -L "$bin" | grep -Eiq '(WebKit|SafariServices|JavaScriptCore)\.framework'; then
      echo "arch-check: [no-webkit] $(basename "$bin") links a web framework:"
      otool -L "$bin" | grep -Ei '(WebKit|SafariServices|JavaScriptCore)\.framework' || true
      bad=1
    fi
  done
  if [ "$found" -eq 0 ]; then
    echo "arch-check: no built products in $dir" >&2
    exit 2
  fi
  [ "$bad" -eq 0 ] && echo "arch-check: $found binaries link no web framework"
  exit "$bad"
fi

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"

# Strip // and /* */ comments outside string literals, keeping line numbers.
strip_comments() {
  awk '
    BEGIN { block = 0 }
    {
      line = $0; out = ""; i = 1; n = length(line); instr = 0
      while (i <= n) {
        c = substr(line, i, 1); d = substr(line, i, 2)
        if (block) {
          if (d == "*/") { block = 0; i += 2; continue }
          i++; continue
        }
        if (instr) {
          if (c == "\\") { out = out substr(line, i, 2); i += 2; continue }
          if (c == "\"") { instr = 0 }
          out = out c; i++; continue
        }
        if (d == "//") break
        if (d == "/*") { block = 1; i += 2; continue }
        if (c == "\"") { instr = 1 }
        out = out c; i++
      }
      print out
    }' "$1"
}

violations=0
report() { # rule file line text
  echo "arch-check: [$1] $2:$3: $(echo "$4" | sed -e 's/^[[:space:]]*//')"
  violations=$((violations + 1))
}

# check_joined RULE FILE ERE: the rule against the comment-stripped file joined into one
# line, so a call split over lines cannot hide (reported at line 0).
check_joined() {
  local rule="$1" file="$2" pattern="$3"
  local joined
  joined="$(strip_comments "$file" | tr '\n' ' ')"
  if printf '%s' "$joined" | grep -qE -- "$pattern"; then
    if ! strip_comments "$file" | grep -qE -- "$pattern"; then
      report "$rule" "$file" 0 "(split over lines) $(printf '%s' "$joined" | grep -oE -- "$pattern" | head -1)"
    fi
  fi
}

# check RULE FILE ERE [-i]
check() {
  local rule="$1" file="$2" pattern="$3" flags="${4:-}"
  local hits
  hits="$(strip_comments "$file" | grep -nE $flags -- "$pattern" || true)"
  [ -z "$hits" ] && return 0
  while IFS= read -r hit; do
    report "$rule" "$file" "${hit%%:*}" "${hit#*:}"
  done <<EOF
$hits
EOF
}

files="$(find Sources Tests -name '*.swift' -type f 2>/dev/null | sort; [ -f Package.swift ] && echo Package.swift)"
if [ -z "$files" ]; then
  echo "arch-check: no Swift sources under $ROOT" >&2
  exit 2
fi

transport="Sources/NWAdapters/ReadOnlyHTTP.swift"
for f in $files; do
  # no-webkit — every target, tests included.
  check no-webkit "$f" '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(class[[:space:]]+|struct[[:space:]]+)?(WebKit|SafariServices|JavaScriptCore)([[:space:].]|$)'
  check no-webkit "$f" '(^|[^A-Za-z0-9_])(WKWebView|WKWebViewConfiguration|WKNavigationDelegate|WKUIDelegate|WebView|WebPage|SFSafariViewController|JSContext|JSValue)([^A-Za-z0-9_]|$)'

  # no-process — every target, tests included (drills spawn from scripts, not Swift).
  check no-process "$f" '(^|[^A-Za-z0-9_])(Process|NSTask|posix_spawn|posix_spawnp|NSAppleScript|NSUserScriptTask|NSUserUnixTask|NSUserAppleScriptTask|NSUserAutomatorTask|OSAScript|NSWorkspace|popen|fork|vfork|execv|execve|execvp|execvP|execl|execlp|execle)([^A-Za-z0-9_]|$)'
  check no-process "$f" '(^|[^A-Za-z0-9_.])system[[:space:]]*\('
  # Dynamic lookup could reach a spawning API by name.
  check no-process "$f" '(^|[^A-Za-z0-9_])(dlopen|dlsym|NSClassFromString|NSSelectorFromString|objc_getClass|objc_lookUpClass|objc_getRequiredClass)([^A-Za-z0-9_]|$)'

  # inert-text — untrusted text is never interpreted as markup (D-016).
  check inert-text "$f" 'AttributedString[[:space:]]*\([[:space:]]*markdown'
  check inert-text "$f" '(DocumentType|documentType)[^A-Za-z]*\.?(html|rtf|rtfd)([^A-Za-z]|$)'
  check inert-text "$f" 'NSAttributedString[[:space:]]*\([[:space:]]*(html|rtf)'
  # SwiftUI reads a Text string literal (with any interpolation) as a
  # LocalizedStringKey: Markdown and links. Anything not a fixed literal must
  # use Text(verbatim:).
  check inert-text "$f" 'Text[[:space:]]*\([[:space:]]*"[^"]*\\\('
  check inert-text "$f" '(^|[^A-Za-z0-9_])LocalizedStringKey[[:space:]]*\('
  # Calls split over lines: the same rules on the file joined into one line.
  check_joined inert-text "$f" 'AttributedString[[:space:]]*\([[:space:]]*markdown'
  check_joined inert-text "$f" 'NSAttributedString[[:space:]]*\([[:space:]]*(html|rtf)'
  check_joined inert-text "$f" 'Text[[:space:]]*\([[:space:]]*"[^"]*\\\('

  case "$f" in
    Sources/NWCore/* | Sources/NWCredentials/* | Sources/NWAdapters/* | Sources/NWFixtures/*)
      check pure-packages "$f" '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+(SwiftUI|AppKit|UIKit|Cocoa)([[:space:].]|$)'
      ;;
  esac

  case "$f" in
    Sources/NWFixtures/*)
      # The fixture server answers connections; it is never linked into the app
      # (checked below).
      ;;
    Sources/*)
      if [ "$f" != "$transport" ]; then
        # Only the bounded transport may touch URLSession or build a URLRequest.
        check get-only "$f" '(^|[^A-Za-z0-9_])(URLSession|URLRequest|NSMutableURLRequest|CFHTTPMessage|NWConnection|CFStream|NSStream|URLSessionWebSocketTask)([^A-Za-z0-9_]|$)'
      fi
      if [ "$f" != "Sources/NWCore/EventStore.swift" ]; then
        # Reading by URL can fetch over the network; only the store reads files
        # (its own segments).
        check get-only "$f" '(^|[^A-Za-z0-9_])(Data|NSData|String|NSString|NSDictionary|NSArray)[[:space:]]*\([[:space:]]*contentsOf'
      fi
      ;;
  esac
  case "$f" in
    Sources/NWAdapters/*)
      check get-only "$f" '"(POST|PUT|PATCH|DELETE|HEAD|OPTIONS|CONNECT|TRACE)"' -i
      check get-only "$f" '(httpBody|httpBodyStream)[[:space:]]*=[^=]'
      check get-only "$f" '(^|[^A-Za-z0-9_])(uploadTask|streamTask|webSocketTask)([^A-Za-z0-9_]|$)|\.upload[[:space:]]*\('
      if [ "$f" = "$transport" ]; then
        # Exactly one method assignment, and it is GET.
        hits="$(strip_comments "$f" | grep -nE 'httpMethod[[:space:]]*=[^=]' || true)"
        count="$(printf '%s' "$hits" | grep -c . || true)"
        while IFS= read -r hit; do
          [ -z "$hit" ] && continue
          text="${hit#*:}"
          if ! echo "$text" | grep -Eq 'httpMethod[[:space:]]*=[[:space:]]*"GET"[[:space:]]*$'; then
            report get-only "$f" "${hit%%:*}" "$text"
          fi
        done <<EOF
$hits
EOF
        if [ "$count" -ne 1 ]; then
          report get-only "$f" 0 "expected exactly one httpMethod assignment (GET), found $count"
        fi
      else
        check get-only "$f" 'httpMethod[[:space:]]*=[^=]'
      fi
      ;;
  esac
done

# The app's targets must not reach the fixtures (a server that is not GET-only), directly
# or through another target, however the declarations are laid out.
if [ -f Package.swift ]; then
  reach="$(strip_comments Package.swift | python3 -I -c '
import re, sys
text = sys.stdin.read()
targets = {}
for m in re.finditer(r"\.(target|executableTarget|testTarget)\s*\(", text):
    depth, i = 1, m.end()
    while i < len(text) and depth:
        depth += {"(": 1, ")": -1}.get(text[i], 0)
        i += 1
    body = text[m.end():i - 1]
    name = re.search(r"name\s*:\s*\"([^\"]+)\"", body)
    if not name:
        continue
    deps = re.search(r"dependencies\s*:\s*\[(.*?)\]", body, re.S)
    found = re.findall(r"\"([^\"]+)\"", deps.group(1)) if deps else []
    targets[name.group(1)] = found
for root in ["NWApp", "NWShell", "NWCore", "NWAdapters", "NWCredentials"]:
    if root not in targets:
        continue
    seen, stack, path = set(), [(root, [root])], None
    while stack:
        name, via = stack.pop()
        if name == "NWFixtures":
            path = via
            break
        if name in seen:
            continue
        seen.add(name)
        for dep in targets.get(name, []):
            stack.append((dep, via + [dep]))
    if path:
        print(root + " reaches NWFixtures: " + " -> ".join(path))
')"
  while IFS= read -r line; do
    [ -n "$line" ] && report get-only Package.swift 0 "$line"
  done <<REACH
$reach
REACH
fi

if [ ! -f "$transport" ]; then
  report get-only "$transport" 0 "the bounded transport is missing"
fi

if [ "$violations" -gt 0 ]; then
  echo "arch-check: $violations violation(s)"
  exit 1
fi
echo "arch-check: $(echo "$files" | wc -l | tr -d ' ') files clean (no-webkit, no-process, pure-packages, get-only, inert-text)"
