# Roadmap

The guide's four steps — native shell, read-only value, evidence-linked
assistance, one controlled action — in a sequence that can actually be
reached (D-011). **Exploration** (N0–N2) is time-boxed, read-only and
allowed now; it ends in the **promotion review**. Only a promoted project
continues to N3–N5. Mapping: guide step 1 → N1 · step 2 → N2 · step 3 → N3 ·
step 4 → N4; the workspace's milestone-0 rule → N0; signed distribution →
N5.

**Time box.** Exploration stops at the earlier of three calendar weeks of
work or 15 working sessions; an extension needs a recorded decision. It
never takes time from an active product's gate.

**Status rule.** A status cell may say *Done* only when it names the tests
and the evidence path that prove the gate. Anything else is *Planned*,
*In progress* or *Blocked (W-n)*. Evidence measured on a busy machine is a
smoke observation.

| Step | Builds | Proves (gate) | Status |
|---|---|---|---|
| **N0 — spine and profiling literacy** (exploration) | `xcode-select` pointed at Xcode.app (a development Mac with Xcode exists; it currently points at the command-line tools); SwiftPM packages for the connection model, ingest and index; the replay fixture server; `scripts/check.sh` and a CI job on a GitHub-hosted macOS runner with a pinned Xcode: `swift format lint --strict`, `swift build`, `swift test`, the architecture checks below; the first load scenario: a headless package replay of 1,000,000 events through the bounded queue and index; the first failure drill: the connection state machine against a fixture server that is killed and restarted; the learning drill: reproduce a UI stall, locate it in Instruments, verify the fix | CI green on the first commit; the package replay commits throughput, drops, gap counts and peak memory, with gap counts equal to drops; `disconnect-restart` at package level passes (stale with timestamp, backoff, zero duplicate rows); before and after Instruments traces of the stall committed; Mac, macOS, Xcode and build recorded as the baseline | Planned — can start now |
| **N1 — native shell** (exploration) | SwiftUI navigation, menus, shortcuts, accessibility baseline (VoiceOver labels, full keyboard navigation); pairing flow; Keychain this-device-only; App Sandbox with the network-client entitlement only and the hardened runtime (D-018); connect, disconnect, stale and revoked states | UI tests green; the shell passes the no-WebKit and no-process-spawning checks; **revocation half of failure case 4** (`revoked-credential`): first 401 → "authority revoked", polling stops, data kept and labeled stale, re-pair offered | Planned |
| **N2 — read-only value** (exploration) | The Service Monitor adapter, `GET`-only (D-013), paired with a local instance under the development exception (D-015); bounded, searchable, redacted history; the text sanitizer (D-016) and redactor (D-017); select-a-failure detail view | **Failure case 1, stale half**, against the fixture and a real local restart; **failure case 2** in the running app under Instruments; search p95 over 10,000 UI queries against the 200 ms target; 1,000 events/s sustained; the **1,000,000-event run** through the app committed; `hostile-log-lines` and the secret-corpus redaction tests pass; a test proves the read-only adapter cannot build a non-`GET` request; startup time and idle CPU recorded | Planned |
| **Promotion review** | The pre-registered comparison (D-012) | The promotion gate in `END_GOAL.md` — pass: promote to an active project; miss: stop, keep the evidence | Blocked (W-3) until N2's gate passes |
| **N3 — evidence-linked assistance** (after promotion) | Optional AI adapter over selected, redacted, previewed evidence; the capability allowlist; provider-absent mode | **Failure case 3, allowlist half** (`unsafe-proposal`): every out-of-allowlist proposal refused and shown with its reason; approval never changes the token or its scope; uncertainties visible in summaries; the app fully useful with no provider | Planned (needs W-3) |
| **N4 — one controlled action** (after promotion) | The one reversible action — pause/resume one monitor (D-025): exact-parameter confirmation, state read-back, idempotency key, the local audit record (D-020), verified result | **Failure case 1, action half**: 1,000 forced disconnects mid-action, exactly one effect each, `uncertain` shown then read back; **failure case 3, service half**: a request outside the paired scope is refused by the service with 403 | Blocked (W-2) |
| **N5 — signed release** (after promotion) | Developer ID signing, notarization, Sparkle with an EdDSA-signed appcast (D-019); local-state schema migrations; the supported macOS matrix (D-023); the redacted diagnostics export | **Failure case 4, update half**: pairings, preferences and Keychain items survive N → N+1; an incompatible protocol opens the diagnostic view; the release gate in `END_GOAL.md` | Blocked (W-1, W-4) |

### N0 architecture checks

Run by `scripts/check.sh` in CI from the first commit:

- no `import WebKit`, `WKWebView` or other web-view type in any target;
- no `Process`, `NSTask`, `posix_spawn`, `system` or `NSAppleScript` in any
  target;
- the pure packages (connection model, ingest, index, sanitizer, redactor)
  import neither SwiftUI nor AppKit;
- the read-only adapter exposes no request builder for a method other than
  `GET`.

### N0 status

*Planned.* Updated as each slice lands, with the commit that proves it.

## Later extensions (explicit contracts required)

Additional reversible actions, a durable workflow runner adapter (through
its public API, once it offers read-scoped keys), JavaScript-runtime
executions and Colophon release receipts (the guide's full direction), iOS,
Linux/Windows native clients, an FFI bridge to Rust service internals (only
after a measured need, D-005), and any AI capability beyond summarize and
propose. Each gets its own contract before work starts.
