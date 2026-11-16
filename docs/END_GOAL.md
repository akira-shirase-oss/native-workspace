# Native Developer Workspace — end goal

**One investigation workflow, native to macOS, that beats the terminal.**

A native workbench for inspecting and operating the portfolio's own
services. Its first usefulness is a single reliable investigation workflow:
**connect an authorized service → inspect status/logs → select a failed
operation → review evidence and proposed action → authorize → observe the
result.** The services remain the authority for everything shown and done;
the app is a well-behaved client, not a second control plane.

This is guide 10 of the series, marked OPTIONAL CONCEPT by the guide
itself. The end goal below describes what the system *is* if promoted;
until the ship gate is met it is a planning basis, not a build commitment.

## In scope (the first useful release)

- A native shell: SwiftUI navigation, menus, shortcuts, accessibility,
  AppKit where appropriate — no webview-hosted UI.
- Explicit pairing with authorized services (read-only by default):
  connect, view status, search bounded log history, inspect a failure.
- Honest connection lifecycle: disconnected/stale states labeled with
  timestamps; reconnect without duplicating anything.
- Evidence-linked assistance: an AI adapter summarizes *selected, redacted*
  evidence; uncertainties stay visible; the app is fully useful with no
  provider configured.
- Exactly one explicitly permitted, reversible, scoped action —
  confirmation against exact parameters, an audit record, verified result —
  added only after the read-only experience is useful.
- Credentials in the system Keychain; a small local preferences/index with
  an explicit data lifecycle; scoped file access.
- Signed distribution with documented update behavior.

## Out of scope (each needs an explicit future decision)

- iOS, and separate Linux/Windows native clients.
- More actions or write workflows beyond the first reversible command.
- An FFI bridge to Rust services — only after a measured need (D-005).
- Dependence on any AI provider — assistance is an adapter, absent by
  default.
- A launch commitment: the guide does not commit to shipping another
  product.

## Non-negotiable invariants

1. **The service is the only authority.** Status, history, and action
   results come from the service's own versioned API or permissioned IPC —
   the same contract every other client uses. The desktop never bypasses
   service authorization, and never holds broader rights than the token it
   was granted.
2. **Read-only by default; least scope always.** Each service is paired
   explicitly with minimum token scopes. Destructive or externally visible
   actions confirm against exact parameters. A model-generated shell string
   never reaches an unrestricted terminal; an approval never widens the
   granted capability.
3. **Honest staleness.** Disconnected data is shown *as stale* with
   timestamps — never presented as current. `unknown`/`uncertain` are
   first-class displayed states, not errors to hide.
4. **Bounded everything, visible gaps.** History, event queues, retention
   and the local index all have limits. Overload produces explicit gap
   markers in the view — never silent loss that looks complete.
5. **Authorize at most once.** Every permitted action carries an
   idempotency key to the service; a reconnect, retry or relaunch can never
   produce a second effect. Uncertainty about an in-flight action is
   surfaced, reconciled, never hidden.
6. **The main actor stays responsive.** File parsing, network work and
   model calls run off it; obsolete queries are cancelled; long lists are
   virtualized; incoming updates are batched. Native tooling is not itself
   a performance guarantee — responsiveness is measured, not assumed.

## Required failure cases

Contract, not options — each must be proven before the gate review:

| Trigger | Required result |
|---|---|
| Service unreachable or restarts | Show disconnected/stale data with timestamps; reconnect without duplicating an authorized action |
| 10,000 events arrive at once | Bounded queues and bounded visible history; UI stays responsive; dropped/log gaps are exposed, not hidden |
| AI proposes an unsafe command | Rejected outside the capability allowlist; requesting approval never grants unrestricted process access |
| App update or credential revocation | Compatible local state preserved; renewed authority required; a rollback/diagnostic route kept |

## Ship gate

Promote this concept to an active project **only after one native workflow
is clearly more useful than the existing terminal or web interface** —
demonstrated on the same investigation task, with the four failure cases
above proven and the workload evidence recorded. "Clearly more useful" is
the guide's wording; the comparison method (same task, timed, honest
notes on what was faster or missing) is fixed before the gate review, not
after — see open questions in `ARCHITECTURE.md`.

## Evidence plan

Record the Mac, macOS, Xcode/build and dataset for every run — no evidence
is valid without them. Guide workloads (proposed acceptance targets, *not*
measurements): a 10,000-row history; 1,000 incoming events/s with bounded
retention; a 10,000-event burst; local search p95 under 200 ms after
indexing. Instruments evidence for hangs, main-actor work, allocations and
energy; startup time and idle CPU measured *before* AI assistance is added.
Compare identical workloads only — never framework marketing claims.
Full runs follow the workspace standard: ≥1,000,000 units where a traffic
unit exists (events ingested, searches, reconnect cycles); results
committed with machine + commit; misses kept as evidence, never rerun
until green.
