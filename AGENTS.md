# Native Developer Workspace — agent instructions

An OPTIONAL-TRACK concept: a macOS-native workbench for the workspace's own
services (Service Monitor, durable-runner, later jsrt executions and
Colophon release receipts). Contract:
`../../docs/Project_Guides/10_Native_Developer_Workspace.docx` (guide 10, marked
OPTIONAL CONCEPT). No code exists yet — these rules bind the moment any is
written, and they strengthen, never weaken, `../../AGENTS.md`.

## Read first

1. `docs/END_GOAL.md` — what done means, scope, the six invariants, the
   four required failure cases, the promotion gate.
2. `docs/ARCHITECTURE.md` — sources of truth, components, data paths,
   planned layout, the open questions list (do not guess past it).
3. `docs/DECISIONS.md` — native-only UI, service authority, read-only
   first, no-FFI, bounded retention with visible gaps.
4. `docs/ROADMAP.md` — N0–N4 order; every status is "Planned — optional
   track" until the maintainer promotes the concept.

## Non-negotiables

1. **Optional until promoted.** Do not scaffold code, create an Xcode
   project, or present this as an active build. Promotion requires the
   gate: one native workflow *demonstrated* clearly more useful than the
   existing terminal or web interface on the same task.
2. **Native means native.** No Tauri, Electron, or webview-hosted UI
   anywhere in the app. Reusing a Rust service/protocol is expected;
   embedding a web page as the interface is not.
3. **The service is the only authority.** The app calls the same versioned
   API / permissioned IPC every other client uses, with the same
   authorization. Never add a desktop-only bypass, and never hold broader
   rights than the paired token's scopes.
4. **Read-only by default.** Explicit pairing per service, minimum token
   scopes, Keychain-only credentials. Destructive or externally visible
   actions confirm against *exact parameters*. A model-generated shell
   string never reaches an unrestricted terminal; an approval never widens
   the granted capability.
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
   standard — ≥1,000,000 units where a traffic unit exists (events
   ingested, searches, reconnect cycles) — and misses are kept, never
   rerun until green. Numbers from this machine are development
   observations, never production capacity.

## Platform rules (when code exists)

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
disconnect-mid-action, unsafe-proposal, revoked-credential), and a
`perf/` workload scenario where a traffic unit exists. Every fixed bug
gets a test that fails without it. UI stalls follow the guide's drill:
reproduce, locate in Instruments, verify the fix, commit the traces.

## Verification gate (planned — binds when code exists)

`xcodebuild test` + the UI suite before every commit; `swift test` for the
packages; Instruments evidence for any change on the ingest, search or
action path; the four contract failure cases re-proven before the N4 gate
review.
