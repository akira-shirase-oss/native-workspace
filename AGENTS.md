# Native Developer Workspace — agent instructions

An OPTIONAL-TRACK concept: a macOS-native workbench for the portfolio's own
services (Service Monitor first; later the durable workflow runner,
JavaScript-runtime executions and Colophon release receipts). Contract: the
engineering guide `10_Native_Developer_Workspace.docx` (marked OPTIONAL
CONCEPT; kept in the maintainer's workspace under `docs/Project_Guides/`,
not in this repository). N0 code exists (exploration only, see
`docs/ROADMAP.md`); these rules bind it and everything after, and they
strengthen, never weaken, the workspace rules.

## Read first

1. `docs/END_GOAL.md` — what done means, scope, the seven invariants, the
   four required failure cases with their tests and pass conditions, the
   promotion gate and the release gate.
2. `docs/ARCHITECTURE.md` — sources of truth, components, data paths,
   planned layout.
3. `docs/DECISIONS.md` — D-001–D-025 and the questions still open (do not
   guess past them).
4. `docs/ROADMAP.md` — exploration N0–N2, the promotion review, then N3–N5
   only if promoted; a status cell says *Done* only with named tests and
   an evidence path.

## Non-negotiables

1. **Exploration, then promotion** (D-011). N0–N2 may be built as a
   time-boxed, read-only exploration: code and an Xcode project are allowed,
   labeled exploration, development-signed, never distributed or presented
   as an active product. N3–N5 (assistance, the action, signed release)
   start only after the promotion gate passes: the read-only workflow
   *demonstrated* clearly more useful than the existing terminal or web
   interface on the pre-registered comparison (D-012).
2. **Native means native.** No Tauri, Electron, or webview-hosted UI
   anywhere in the app. Reusing a Rust service/protocol is expected;
   embedding a web page as the interface is not.
3. **The service is the only authority, and its token scope is the
   security boundary** (D-014). The app calls the same versioned API every
   other client uses, with the same authorization. Never add a desktop-only
   bypass. The allowlist and confirmation sheets are defense in depth. The
   only exception is D-015: during exploration, an admin token for a
   loopback Service Monitor instance, with a `GET`-only adapter.
4. **Read-only by default.** Explicit pairing per service, minimum token
   scopes, Keychain-only credentials (this device only). Destructive or
   externally visible actions confirm against *exact parameters*. No target
   contains process-spawning code, so a model-generated shell string has
   nowhere to go; an approval never widens the granted capability. Log text
   is untrusted and rendered inert (D-016); secrets are redacted before
   indexing or sending (D-017).
5. **Honest states, bounded everything.** Stale data is labeled
   stale-with-timestamp; `unknown`/`uncertain` are displayed states.
   History, queues, retention and the index are all bounded; dropped
   events surface as visible gap markers — silent loss that looks complete
   is a defect.
6. **Authorize at most once.** Every permitted action carries an
   idempotency key; reconnect/retry/relaunch can never produce a second
   effect. Uncertainty about an in-flight action is shown, then reconciled
   against the service — never retried blind.
7. **Main-actor responsiveness is measured, not assumed.** Long work off
   the main actor, obsolete queries cancelled, updates batched, long lists
   virtualized. Instruments evidence — not "it's SwiftUI so it's fast" —
   backs every responsiveness claim.
8. **Evidence over claims.** The guide's numbers are *proposed lab
   workloads and acceptance targets*, not measurements. Every artifact
   (Instruments trace, workload run, UI-test result) records Mac model,
   macOS, Xcode/build, dataset and commit. Full runs meet the workspace
   standard: the 1,000,000-unit run counts events ingested by the app from
   the local replay fixture server (D-022); the paired service is never the
   load target. Misses are kept, never rerun until green. Numbers from
   this machine are development observations, never production capacity.

## Platform rules

- Swift structured concurrency and typed models for client logic; AppKit
  where SwiftUI is insufficient. Pure logic lives in SwiftPM packages so
  `swift test` covers it without the simulator.
- Requires a supported macOS + Xcode environment; the Ubuntu Dell stays the
  Rust service/test machine. Do not claim cross-platform — Swift on Linux
  has no SwiftUI.
- No FFI bridge to Rust before a measured need (D-005).
- Security-sensitive action code (pairing, scopes, the allowlist, the
  action pipeline) is separately reviewed per the guide's upkeep clause.
- The Rust rules in sibling projects (`rust-mastery`, toolchain pin, lint
  gate) apply only if this project's work touches the Rust services
  themselves — that work happens in those projects, under their rules.

## Testing rule (workspace standard, adapted)

Every feature ships in the same change: XCTest coverage, a fixture path
under `fixtures/` (recorded service responses + event streams — burst-10k,
disconnect-restart, disconnect-mid-action, unsafe-proposal,
revoked-credential, hostile-log-lines, secret-corpus), and a
`perf/` workload scenario where a traffic unit exists. Every fixed bug
gets a test that fails without it. UI stalls follow the guide's drill:
reproduce, locate in Instruments, verify the fix, commit the traces.

## Toolchain on this Mac

`xcode-select` points at the Command Line Tools; prefix every Swift/Xcode
command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
(`scripts/check.sh` does). CI pins Xcode 26.6 on `macos-26`; nothing newer
than the deployment target (macOS 26) may be used without `#available`.

## Verification gate (CI from the first N0 commit)

`scripts/check.sh` runs what CI runs on a GitHub-hosted macOS runner with a
pinned Xcode: `swift format lint --strict`; `swift build` and `swift test`
for the packages; `xcodebuild test` with the UI suite once the app target
exists; the architecture checks in `docs/ROADMAP.md` §N0 (no WebKit, no
process spawning, pure packages free of SwiftUI/AppKit, `GET`-only
read-only adapter); the drills of every finished milestone. Instruments
evidence for any change on the ingest, search or action path. The failure
cases each gate names are re-proven on the commit that claims the gate.
