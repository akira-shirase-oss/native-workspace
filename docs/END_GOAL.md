# Native Developer Workspace — end goal

**One investigation workflow, native to macOS, that beats the terminal.**

A native workbench for inspecting and operating the portfolio's own
services. Its first usefulness is a single reliable investigation workflow:
**connect an authorized service → inspect status/logs → select a failed
operation → review evidence and proposed action → authorize → observe the
result.** The services remain the authority for everything shown and done;
the app is a well-behaved client, not a second control plane.

This is guide 10 of the series, marked OPTIONAL CONCEPT by the guide
itself. The plan is reachable in two gates (D-011): a time-boxed,
read-only exploration ends in the **promotion gate**; only a promoted
project goes on to assistance, one action and the **release gate**.
Contract: the engineering guide `10_Native_Developer_Workspace.docx`
(outside this repository); the guide wins on conflict. Every number below
is a proposed lab workload or acceptance target, not a measurement.

## In scope (the first useful release)

The guide's first useful release is the read-only console; the action
comes only after it is useful.

- A native shell: SwiftUI navigation, menus, shortcuts, accessibility,
  AppKit where appropriate — no webview-hosted UI.
- Explicit pairing with one authorized service, Service Monitor (D-013),
  read-only by default: connect, view status, search bounded log history,
  inspect a failure.
- Honest connection lifecycle: disconnected and stale states labeled with
  timestamps; reconnect without duplicating anything.
- Untrusted log text rendered safely (D-016) and secrets redacted before
  anything is indexed or sent anywhere (D-017).
- After promotion: evidence-linked assistance — an optional AI adapter
  summarizes *selected, redacted* evidence; uncertainties stay visible; the
  app is fully useful with no provider configured.
- After promotion: exactly one explicitly permitted, reversible, scoped
  action (D-025) — confirmation against exact parameters, an audit record
  (D-020), a verified result.
- Credentials in the system Keychain, this device only; a small local
  preferences file and index with an explicit data lifecycle; scoped file
  access; App Sandbox and hardened runtime (D-018).
- Signed distribution with documented update behavior (D-019) — at the
  release gate, not during exploration.

## Out of scope (each needs an explicit future decision)

- iOS, and separate Linux/Windows native clients.
- More actions or write workflows beyond the first reversible command.
- An FFI bridge to Rust services — only after a measured need (D-005).
- Dependence on any AI provider — assistance is an adapter, absent by
  default.
- Changes to the paired services. Scoped tokens and any new API they need
  are built in those projects, under their own rules (W-1, W-2).
- A launch commitment: the guide does not commit to shipping another
  product.

## Non-negotiable invariants

1. **The service is the only authority.** Status, history, and action
   results come from the service's own versioned API — the same contract
   every other client uses. The desktop never bypasses service
   authorization.
2. **The token scope is the security boundary; the app's allowlist is
   defense in depth.** Each service is paired explicitly with the minimum
   token scope, and the service must refuse anything outside it. The app's
   capability allowlist and confirmation sheets reduce mistakes; they are
   never the reason an unsafe request fails (D-014). A model-generated shell
   string never reaches a terminal — the app contains no process-spawning
   code at all (D-018) — and an approval never widens the granted
   capability. The one development-only exception is D-015.
3. **Honest staleness.** Disconnected data is shown *as stale* with
   timestamps — never presented as current. `unknown` and `uncertain` are
   first-class displayed states, not errors to hide.
4. **Bounded everything, visible gaps.** History, event queues, retention
   and the local index all have limits (D-021). Overload produces gap
   markers whose counts equal the events dropped — never silent loss that
   looks complete.
5. **Authorize at most once.** Every permitted action carries an
   idempotency key and is checked against the service's current state
   before it is sent; a reconnect, retry or relaunch can never produce a
   second effect. Uncertainty about an in-flight action is surfaced, read
   back and reconciled, never retried blind.
6. **The main actor stays responsive.** File parsing, network work and
   model calls run off it; obsolete queries are cancelled; long lists are
   virtualized; incoming updates are batched. "Responsive" means no
   main-thread hang of 250 ms or more as reported by Instruments.
7. **Untrusted text stays inert, secrets stay local.** Log lines are
   untrusted: terminal escapes, control characters and bidi overrides are
   shown as visible escapes, never interpreted (D-016). Secret-shaped text
   is redacted before it is indexed, and nothing reaches an AI provider
   without being selected, redacted and previewed (D-017).

## Required failure cases (contract, not options)

| Trigger | Required result | Proven by | Pass condition | From |
|---|---|---|---|---|
| Service unreachable or restarts | Show disconnected/stale data with timestamps; reconnect without duplicating an authorized action | Drill `disconnect-restart`: the fixture server is killed and restarted at random points 1,000 times, and a real local Service Monitor is restarted during a session. The action half: 1,000 forced disconnects at random points of an in-flight action | Within one poll interval plus 1 s every view from that service shows "stale since T"; no stale value is ever labeled live (UI test); reconnect resumes with backoff (1 s doubling to a 30 s cap, with jitter) and without re-pairing; zero duplicate rows in the index; action half: an interrupted action shows `uncertain`, is read back, and the fixture counts exactly one effect in every run | stale half N0 (package) and N2 (app); action half N4 |
| 10,000 events arrive at once | Bound queues and visible history; preserve UI responsiveness and expose dropped/log gaps | Fixture `burst-10k` against the running app with Instruments attached, plus the package-level replay in CI | No main-thread hang of 250 ms or more; queue depth never exceeds its bound (D-021); the sum of gap-marker counts equals the drop counter equals events sent minus events retained, per the fixture's ledger; peak memory is recorded, stays under the budget set from N0's measurement, and does not grow across ten repeated bursts once retention is full | package N0, app N2 |
| AI proposes an unsafe command | Reject outside the capability allowlist; requesting approval never grants unrestricted process access | Fixture `unsafe-proposal`: shell strings, `curl … \| sh`, an API call outside the allowlist, an allowlisted action with out-of-scope parameters, a log line carrying injected instructions. CI architecture check: no `Process`, `NSTask`, `posix_spawn`, `system` or `NSAppleScript` in any target. Service-side test: a request outside the paired token's scope | Every proposal outside the allowlist is shown as refused with its reason; zero processes spawned (there is no code that could); approving a proposal never changes the stored token or its scope; the service answers 403 to the out-of-scope request — proof that the boundary holds without the app | architecture check N0; allowlist N3; service-side refusal N4 |
| App update or credential revocation | Preserve compatible local state, require renewed authority and keep a rollback/diagnostic route | Revocation: fixture `revoked-credential` (the service answers 401 mid-session), UI test. Update: install release N, create pairings and state, update to N+1 through a test appcast; schema-migration tests from every released version | Revocation: on the first 401 the service is marked "authority revoked", polling stops (no retry loop with the dead token), local data stays visible labeled stale, and re-pairing is offered. Update: pairings, preferences and Keychain items survive; an incompatible service protocol opens the diagnostic view instead of failing silently; the previous signed build stays downloadable and a redacted diagnostics export works | revocation N1; update N5 |

## Promotion gate (end of exploration)

The guide: **promote this concept to an active project only after one
native workflow is clearly more useful than the existing terminal or web
interface.** Testable form, after N2 (D-012):

1. The comparison protocol is committed before the first trial; its commit
   hash is recorded with the results.
2. At least three investigation tasks, each a seeded failure in a local
   Service Monitor instance (for example a monitor flapping on timeouts, an
   incident whose cause sits in a check's error detail, a coverage gap from
   missed slots). Each task is done once with the existing interfaces (the
   CLI and the web dashboard) and once with the app, on different but
   equivalent seeds, alternating which interface goes first.
3. Recorded per trial: time to the correct diagnosis, counted steps
   (commands, clicks, context switches), wrong turns, notes.
4. **Pass:** the app reaches the correct diagnosis in every task, its median
   time to diagnosis is at least 30% lower across the tasks, and it needs
   fewer steps in at least two of three tasks. A second person running the
   protocol is preferred, because the maintainer alone is a biased judge.
5. Also required: failure cases 1 (stale half), 2 and 4 (revocation half)
   pass; the 1,000,000-event run is committed; startup time and idle CPU
   are recorded.

A miss ends the track honestly: the evidence is kept, the concept stays a
concept, and N3–N5 do not start.

## Release gate (only after promotion)

The first signed distribution requires all four failure cases passing on
the release commit; a Service Monitor read-only token (W-1) in place of the
development exception; Developer ID signing, notarization and an
EdDSA-signed update feed (W-4, D-019); App Sandbox and hardened runtime;
the supported macOS matrix (D-023) tested; and every security-sensitive
change (pairing, scopes, allowlist, action pipeline) separately reviewed.

## Evidence plan

Record the Mac model, macOS, Xcode and build, dataset and commit for every
run — no evidence is valid without them. Guide workloads, as proposed
targets: a 10,000-row history; 1,000 incoming events/s with bounded
retention; a 10,000-event burst; local search p95 under 200 ms after
indexing. Instruments evidence for hangs, main-actor work, allocations and
energy; startup time and idle CPU measured *before* AI assistance is added.
Compare identical workloads only, never framework marketing claims.

The **1,000,000-unit run** (D-022) counts events ingested by the running
app from the local replay fixture server at 1,000 events/s (about 17
minutes), with bursts of 10,000; it records drops against gap counts, peak
memory and hangs. Search p95 is measured over 10,000 queries through the
UI against the 10,000-row history, and over 1,000,000 headless queries at
the package level for regressions. The paired service is never the load
target — runs against a real local instance are functional checks only.
Results go to `perf/results/` with machine and commit; misses are kept,
never rerun until green; numbers from one Mac are development
observations.

## Release and upkeep

From the guide: track supported macOS releases and APIs (D-023), signing
credentials, accessibility regressions and service-protocol compatibility
(the capability handshake records the protocol version, and an
incompatible one opens the diagnostic view); keep security-sensitive
actions — pairing, scopes, the allowlist, the action pipeline — separately
reviewed; keep the app useful without an AI provider.
