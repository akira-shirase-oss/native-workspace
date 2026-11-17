#!/usr/bin/env bash
# Proves each architecture check can fail: a clean fixture tree passes, then
# every planted violation must make scripts/arch-check.sh exit non-zero and
# name its rule — and comments must neither trigger nor hide a violation.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
check="$here/arch-check.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/nw-arch-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/Sources/NWCore" "$work/Sources/NWAdapters" "$work/Sources/NWShell" \
  "$work/Sources/NWFixtures" "$work/Tests/NWCoreTests"
cat > "$work/Package.swift" <<'EOF'
let package = Package(targets: [
  .target(name: "NWShell", dependencies: ["NWCore", "NWAdapters"]),
  .testTarget(name: "NWShellTests", dependencies: ["NWShell", "NWFixtures"]),
])
EOF
cat > "$work/Sources/NWAdapters/ReadOnlyHTTP.swift" <<'EOF'
import Foundation
struct ReadOnlyRequest {
  let url: URL
  var urlRequest: URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    return request
  }
}
let session = URLSession(configuration: .ephemeral)
EOF
cat > "$work/Sources/NWCore/Clean.swift" <<'EOF'
import Foundation
// Process(), WKWebView and import WebKit in a comment are fine.
/* posix_spawn and NSTask inside a block comment
   spanning lines are fine too: system("x") */
let env = ProcessInfo.processInfo.environment
let url = "http://example.invalid/path"  // a // inside a string is not a comment
let font = Font.system(size: 12)
EOF
cat > "$work/Sources/NWFixtures/Server.swift" <<'EOF'
import Network
func serve(_ connection: NWConnection) {}
EOF

passes=0
fails=0
ok() { passes=$((passes + 1)); echo "  ok   $1"; }
bad() { fails=$((fails + 1)); echo "  FAIL $1"; }

if out="$("$check" "$work" 2>&1)"; then ok "clean tree passes"; else bad "clean tree passes: $out"; fi

# expect_violation NAME RULE FILE CONTENT
expect_violation() {
  local name="$1" rule="$2" file="$3" content="$4"
  local existed=0
  local backup="$work/.backup"
  if [ -f "$work/$file" ]; then existed=1; cp "$work/$file" "$backup"; fi
  printf '%s\n' "$content" >> "$work/$file"
  local out status=0
  out="$("$check" "$work" 2>&1)" || status=$?
  if [ "$status" -ne 0 ] && echo "$out" | grep -q "\[$rule\] $file"; then
    ok "$name -> [$rule]"
  else
    bad "$name: expected [$rule] in $file, exit $status: $out"
  fi
  if [ "$existed" -eq 1 ]; then mv "$backup" "$work/$file"; else rm -f "$work/$file"; fi
}

expect_violation "import WebKit" no-webkit Sources/NWShell/Web.swift 'import WebKit'
expect_violation "@preconcurrency import WebKit" no-webkit Sources/NWShell/Web.swift '@preconcurrency import WebKit'
expect_violation "import SafariServices" no-webkit Tests/NWCoreTests/T.swift 'import SafariServices'
expect_violation "WKWebView type" no-webkit Sources/NWShell/Web.swift 'let view = WKWebView(frame: .zero)'
expect_violation "SwiftUI WebView" no-webkit Sources/NWShell/Web.swift 'var body: some View { WebView(url: url) }'
expect_violation "JavaScriptCore" no-webkit Sources/NWCore/JS.swift 'let context = JSContext()'
expect_violation "Process()" no-process Sources/NWShell/Spawn.swift 'let task = Process()'
expect_violation "Foundation.Process" no-process Sources/NWCore/Spawn.swift 'let task = Foundation.Process()'
expect_violation "NSTask" no-process Sources/NWShell/Spawn.swift 'let task = NSTask()'
expect_violation "posix_spawn" no-process Sources/NWCore/Spawn.swift 'posix_spawn(&pid, path, nil, nil, argv, envp)'
expect_violation "system()" no-process Sources/NWCore/Spawn.swift 'let rc = system("ls")'
expect_violation "fork/exec" no-process Sources/NWCore/Spawn.swift 'if fork() == 0 { execv(path, argv) }'
expect_violation "popen" no-process Sources/NWCore/Spawn.swift 'let pipe = popen("ls", "r")'
expect_violation "NSAppleScript" no-process Sources/NWShell/Spawn.swift 'NSAppleScript(source: "beep")'
expect_violation "NSWorkspace" no-process Sources/NWShell/Spawn.swift 'NSWorkspace.shared.open(url)'
expect_violation "Process in a test target" no-process Tests/NWCoreTests/T.swift 'let task = Process()'
expect_violation "code hidden after a // inside a string" no-process Sources/NWCore/Clean.swift 'let u = "http://x"; let task = Process()'
expect_violation "code after a closed block comment" no-process Sources/NWCore/Clean.swift '/* fine */ let task = Process()'
expect_violation "SwiftUI in a pure package" pure-packages Sources/NWCore/UI.swift 'import SwiftUI'
expect_violation "AppKit in the adapters" pure-packages Sources/NWAdapters/UI.swift 'import AppKit'
expect_violation "POST assignment in an adapter" get-only Sources/NWAdapters/Other.swift 'request.httpMethod = "POST"'
expect_violation "second method assignment in the transport" get-only Sources/NWAdapters/ReadOnlyHTTP.swift 'func set(_ r: inout URLRequest, _ m: String) { r.httpMethod = m }'
expect_violation "method literal" get-only Sources/NWAdapters/Other.swift 'let verb = "delete"'
expect_violation "request body" get-only Sources/NWAdapters/ReadOnlyHTTP.swift 'func body(_ r: inout URLRequest) { r.httpBody = Data() }'
expect_violation "upload task" get-only Sources/NWAdapters/ReadOnlyHTTP.swift 'let t = session.uploadTask(with: request, from: Data())'
expect_violation "URLRequest outside the transport" get-only Sources/NWAdapters/Other.swift 'let r = URLRequest(url: url)'
expect_violation "URLSession outside the adapters" get-only Sources/NWShell/Net.swift 'URLSession.shared.dataTask(with: url).resume()'
expect_violation "raw connection outside the transport" get-only Sources/NWShell/Net.swift 'let c = NWConnection(host: "h", port: 80, using: .tcp)'
expect_violation "app depends on the fixtures" get-only Package.swift '  .target(name: "NWApp", dependencies: ["NWShell", "NWFixtures"]),'
expect_violation "markdown interpretation" inert-text Sources/NWShell/Text.swift 'let a = try AttributedString(markdown: line)'
expect_violation "HTML document" inert-text Sources/NWShell/Text.swift 'let o = [NSAttributedString.DocumentReadingOptionKey.documentType: NSAttributedString.DocumentType.html]'

# Bypasses an earlier version missed (each must fail now).
expect_violation "network read outside the transport" get-only Sources/NWShell/Net.swift 'let d = try Data(contentsOf: URL(string: "http://127.0.0.1:1/api/monitors")!)'
expect_violation "String(contentsOf:) outside the store" get-only Sources/NWAdapters/Other.swift 'let s = try String(contentsOf: url, encoding: .utf8)'
expect_violation "interpolated Text literal" inert-text Sources/NWShell/Text.swift 'var body: some View { Text("Service says: \(untrusted)") }'
expect_violation "LocalizedStringKey from a string" inert-text Sources/NWShell/Text.swift 'let key = LocalizedStringKey(line)'
expect_violation "markdown call split over lines" inert-text Sources/NWShell/Text.swift 'let a = try AttributedString(
    markdown: line)'
expect_violation "dlsym spawn" no-process Sources/NWCore/Spawn.swift 'let f = dlsym(handle, "posix_" + "spawn")'
expect_violation "class looked up by name" no-process Sources/NWShell/Spawn.swift 'let t = NSClassFromString("NS" + "Task")'
expect_violation "app depends on the fixtures over several lines" get-only Package.swift '  .executableTarget(
    name: "NWApp",
    dependencies: ["NWShell", "NWFixtures"]
  ),'
expect_violation "app reaches the fixtures through another target" get-only Package.swift '  .target(name: "NWCore", dependencies: ["NWHelpers"]),
  .target(name: "NWHelpers", dependencies: ["NWFixtures"]),'

# A missing transport is itself a violation.
mv "$work/Sources/NWAdapters/ReadOnlyHTTP.swift" "$work/moved.swift"
if "$check" "$work" > /dev/null 2>&1; then bad "missing transport fails"; else ok "missing transport fails"; fi
mv "$work/moved.swift" "$work/Sources/NWAdapters/ReadOnlyHTTP.swift"

echo "test-arch-check: $passes passed, $fails failed"
[ "$fails" -eq 0 ]
