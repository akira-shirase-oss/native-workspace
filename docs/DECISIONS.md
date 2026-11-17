# Decisions

Deliberate choices, newest last. D-NNN numbering is project-local,
continuing the workspace convention. D-001–D-010 are seeded by the guide;
D-011–D-025 were decided before any code, to make the plan reachable, to
settle the open questions with conservative defaults and to fix gaps a plan
review found. Each is a real trade-off — what was given up is stated, not
just what was chosen. What still needs the maintainer or another project is
under *Open questions (still open)* and in the README's *Blocked on* table.

- **D-001 — Optional track, honestly labeled.** The guide marks itself
  OPTIONAL CONCEPT. These documents are a planning basis: no code, no
  device purchase, no schedule commitment is implied. The cost of honesty
  here is that the project may never build — that is an acceptable
  recorded outcome, not a failure to hide. *Refined by D-011: a time-boxed,
  read-only exploration may write code; promotion decides the rest.*
- **D-002 — Native UI, no webview shell.** SwiftUI + AppKit only; no
  Tauri/Electron/webview-hosted application. Reusing a Rust *service* or
  protocol is fine; reusing a web *page* as the interface is not. Given
  up: the Studio/testbed frontend stack and any cross-platform UI reuse.
  Bought: platform conventions, accessibility, system permissions — which
  are the project's stated reason to exist.
- **D-003 — macOS first, other platforms deferred.** iOS and
  Linux/Windows native clients are each future explicit decisions, not a
  roadmap. Given up: reach. Bought: one platform done properly before the
  investigation workflow is even proven useful. Swift-on-Linux does not
  provide SwiftUI — portability is not claimed anywhere it doesn't exist.
- **D-004 — Services stay authoritative; the desktop is a client.** All
  reads and the one permitted action go through the service's own
  versioned API or permissioned IPC — the same authorization every other
  client gets. Given up: anything the service API doesn't already expose.
  Deliberately so: a desktop bypass with broader rights would break the
  workspace's "one API, no bypass" invariant.
- **D-005 — No FFI bridge before a measured need.** Versioned HTTP or
  permissioned IPC to Rust services first. Given up: sharing Rust domain
  code in-process; some models will be re-declared in Swift. Bought: a
  clean security boundary (the service audits the call, not the
  library), and the bridge is added only when profiling or a concrete
  need justifies it — not aspirationally.
- **D-006 — Read-only first; one reversible action earns its place.** The
  first release ships zero write capability until the read-only console
  is demonstrably useful; then exactly one scoped, reversible command.
  Given up: early "ops dashboard" appeal. Bought: the pairing, scope,
  allowlist and audit machinery is proven before any authority exists to
  abuse.
- **D-007 — Keychain + explicit pairing + minimum scopes.** Credentials
  live only in the system Keychain; each service is paired explicitly
  with the smallest token scope the workflow needs; approval never widens
  a granted capability, and model-generated commands never reach an
  unrestricted terminal. Given up: convenience flows ("just paste a root
  token"). Bought: revocation, blast radius and auditability are real.
  *Neither paired service can issue a scoped token yet; see D-015 for the
  development-only exception and W-1 for what ends it.*
- **D-008 — Bounded retention with visible gaps.** History and event
  queues are capped; overload produces explicit gap markers, never a
  silently truncated view that looks complete. Given up: the appearance
  of infinite history. Bought: honest states under the 10k-burst contract
  case, and memory that stays bounded forever.
- **D-009 — AI assistance is an optional adapter.** The app must be fully
  useful with no provider configured; assistance summarizes only
  *selected, redacted* evidence, marks its output advisory, and leaves
  uncertainties visible. Given up: "AI-native" positioning. Bought: no
  provider dependency in the trust path — the failure case "AI proposes
  an unsafe command" is answered structurally, not by prompt engineering.
  *Restated by D-014: the structural answer is the service's token scope
  plus the absence of any process-spawning code; the allowlist is defense
  in depth.*
- **D-010 — Signing, updates and permissions are product surface.** Signed
  distribution with documented update behavior is part of the feature
  set, not a release-day chore: updates must preserve compatible local
  state, credential revocation must demand renewed authority, and a
  rollback/diagnostic route must exist. Given up: informal unsigned
  distribution. Bought: the fourth required failure case is testable — its
  revocation half from N1, its update half at N5. During exploration the
  app is development-signed and not distributed (D-019).

## Decisions made before code (2026-11-16)

Each states the choice, the reason and what it costs. Numbers are proposed
starting values; changing one needs a measurement and a new entry.

- **D-011 — Exploration, then promotion.** The old rule forbade any code
  until promotion, while the promotion gate required N0–N4 to be built, so
  the gate could never be reached. Now: a time-boxed, read-only
  *exploration* (N0–N2, at most three calendar weeks of work or 15 working
  sessions) may write code in this repository, labeled exploration, with
  development signing and no distribution or product claims. Its last step
  is the promotion review (D-012). Only a promoted project builds N3–N5.
  The guide's own order supports the cut: the read-only console is its
  first useful release, and the action comes only after the read-only
  experience is useful. Adopted because the maintainer asked for work to
  start on every planned project (2026-11-16). Cost: exploration code may
  be thrown away.
- **D-012 — The comparison for "clearly more useful" is pre-registered.**
  The protocol is committed before the first trial: at least three tasks,
  each a seeded failure in a local Service Monitor instance; each done once
  with the existing CLI and web dashboard and once with the app, on
  different but equivalent seeds, alternating which interface goes first;
  time to correct diagnosis, counted steps, wrong turns and notes recorded.
  Pass: the app diagnoses every task correctly, its median time is at least
  30% lower, and it needs fewer steps in at least two of three tasks. A
  second person running the protocol is preferred. Reason: a method chosen
  after the data can be bent to fit it. Cost: three seeded scenarios to
  build and keep working.
- **D-013 — First adapter: Service Monitor over HTTP.** Both candidate
  services expose versioned HTTP APIs, so no local IPC contract is needed.
  Service Monitor has the richer read surface for an investigation
  (monitors, checks, incidents, maintenance), a web dashboard and CLI to
  compare against, and a viewer role in its plans. The adapter polls the
  service's paginated reads at a bounded interval; if a cursor or filter
  the workflow needs is missing, that is a feature request to Service
  Monitor, not a desktop workaround. The read-only build can construct only
  `GET` requests. The durable workflow runner comes later, once it offers
  read-scoped keys. Cost: one service's workflow decides the first design.
- **D-014 — The service's token scope is the security boundary.** The app's
  capability allowlist, confirmation sheets and `GET`-only build are
  defense in depth; the service must refuse anything outside the paired
  scope, and N4 proves it with a service-side 403 test. The app contains no
  process-spawning code at all, enforced in CI, so no model output can
  reach a shell. Reason: a client-side allowlist is UX; anyone holding the
  token can skip the app. Cost: the action the app can offer depends on
  what the service's scopes can express.
- **D-015 — Development-only exception while scoped tokens do not exist.**
  Today Service Monitor authenticates with one admin bearer token, and the
  durable workflow runner requires one API key on mutating and admin routes
  (since 2026-11-16) and leaves reads open on loopback; neither issues
  scoped tokens. During exploration the app pairs only with a Service
  Monitor instance on a loopback address, using its admin token from the
  Keychain; the adapter can send only `GET`; and any token whose scope the
  service cannot report is treated as admin-class and refused for a
  non-loopback endpoint. This weakens invariant 2 for development only. No
  non-loopback pairing and no release until Service Monitor offers a
  read-only token through its public API (W-1). Cost: exploration never
  touches a deployed instance.
  *Amended 2026-11-16 (server identity).* Loopback is not authentication:
  while Service Monitor is down, any local process can bind its port
  (≥ 1024 needs no privilege) and would receive `Bearer <admin>` on the
  next poll. So immediately before every request the app identifies the
  process that would accept a connection to the endpoint's exact address
  (libproc, this user's processes): the owner of a socket bound to that
  address if one exists — the kernel prefers it — otherwise of a wildcard
  socket (0.0.0.0, or :: which also takes IPv4); none, or more than one
  process, is refused. It compares that process's executable path
  (realpath) and code directory hash with the pin: `NW_SMON_EXPECT_EXECUTABLE`
  (and optionally `NW_SMON_EXPECT_CDHASH`), or, unpinned, the first
  listener seen this session (trust on first use). On a mismatch nothing
  is sent — no token, no request — and the service shows stale with the
  reason. A check costs about 2 ms (one scan of this user's processes;
  identities are cached by pid and start time), once per request.
  `localhost` is rewritten to 127.0.0.1, so name resolution never decides
  where the token goes. Residual risks, accepted for exploration only: the
  window between the check and URLSession opening the connection for that
  request (a kept-alive connection stays with the process that accepted
  it); a listener owned by root or another user is invisible to libproc,
  so if one bound the exact address while the paired service held only the
  wildcard, the check would not see it (Service Monitor binds 127.0.0.1
  itself, which leaves no more specific address to take); trust on first
  use pins an impostor that was there first; code running as the same user
  can still read the token from this process. The real fix is server
  authentication in Service Monitor (TLS with a certificate pinned
  at pairing, or a Unix-domain socket checked with `getpeereid`), with W-1.
  *The environment token.* Exploration pairs from `NW_SMON_TOKEN` in the
  process environment. That is weak: such tokens usually sit in plain text
  in a shell profile or script, and every child of the shell that holds them
  inherits them. The app unsets the variable as soon as it has read it (it
  spawns no processes itself), and the environment source is
  exploration-only: N1 pairs through the Keychain (this device only) and
  removes the environment source from the default chain.
- **D-016 — Log text is untrusted and rendered inert.** ANSI and other
  terminal escape sequences (CSI, OSC), C0 and C1 control characters other
  than tab and newline, and the Unicode bidi overrides and isolates
  (U+202A–U+202E, U+2066–U+2069) are shown as visible escapes, never
  interpreted. Fixture `hostile-log-lines` proves it. Reason: escapes and
  bidi overrides can make a log line display something other than what it
  says. Cost: some coloured output loses its colours.
- **D-017 — Redact before persisting or sending.** A redactor removes
  secret-shaped text — `Authorization` values and bearer tokens, URL
  credentials, query parameters such as `token`, `key`, `sig` and `secret`,
  webhook URLs, JWTs, key-shaped strings — before text enters the local
  index or an export. The view shows redacted text by default; "reveal"
  re-fetches one item from the service without persisting it. Anything sent
  to an AI provider is redacted, chosen by the user and previewed byte for
  byte. The redactor is tested against a secret corpus, and it exists at
  N2, before any assistance. Reason: the services' own logs can contain
  secrets, and the app would otherwise index them to disk. Cost: redaction
  false positives hide some harmless text until revealed.
  *N0 exception (2026-11-17):* the redactor does not exist yet, so N0
  persists service text as the service sent it — cut to 8 KiB per event
  (F7), in the private, single-instance store directory (0700 with an
  exclusive lock, since `6683191`), and rendered inert only at display.
  Secret-shaped text in a check detail is therefore on disk in N0 builds.
  Exploration pairs only with loopback scratch instances (D-015), and the
  redactor lands at N2, before any export or assistance.
- **D-018 — Platform hardening.** Keychain items use
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (no sync to other
  devices); the app ships with the App Sandbox (outgoing network entitlement
  only) and the hardened runtime unless a measured need says otherwise; no
  WebKit and no process-spawning API in any target, enforced in CI. Cost:
  features that need broader entitlements need a new decision.
- **D-019 — Distribution and updates: Developer ID, notarization,
  Sparkle.** Direct distribution signed with Developer ID and notarized,
  updating through Sparkle 2 with an EdDSA-signed appcast. The rollback and
  diagnostic route: the previous signed build stays downloadable, and the
  app can export a redacted diagnostics bundle. Local state is versioned;
  a migration never deletes the old file until the new one is written, and
  migrations are tested from every released version. This needs the paid
  Apple Developer Program (W-4); exploration uses development signing and
  is not distributed. The Mac App Store was not chosen for now: every
  update, security fixes included, would wait on App Review, and Developer
  ID with Sparkle is the common path for directly distributed developer
  tools. Cost: an annual fee and update infrastructure, deferred until
  promotion.
- **D-020 — Local audit format.** Append-only JSON Lines in the app's
  container, one record per authorized action: idempotency key, service,
  action, exact parameters, confirmation time, request, response and
  verified post-state. Each record carries the SHA-256 of the previous one,
  so an edit or truncation is detectable; each write is fsynced. Kept for
  one year, exportable. The service's own audit is authoritative where it
  exists. Cost: a hash chain detects tampering; it does not prevent it.
- **D-021 — Ingest bounds and the meaning of "responsive".** Proposed
  starting bounds: an ingest queue of 10,000 events, 50,000 retained rows
  per service, UI batches at most every 100 ms. On overflow new events are
  dropped and counted into an open gap marker (count and time range); the
  gap counts must equal the drop counter. "Responsive" means no main-thread
  hang of 250 ms or more as reported by the Instruments Hangs instrument.
  The bounds are tuned from N0 and N2 measurements with a new entry. Cost:
  under sustained overload, history has holes — visible ones.
  *As built in N0 (2026-11-17):* one window shared by all services —
  50,000 events and 64 MiB in memory, the disk bounded by bytes too — not
  50,000 per service, so a noisy service can evict another's history.
  De-duplication covers the retained window only: an event that left it
  and is offered again is stored again. Today's polls re-read at most about
  5,200 events, far inside the window, so that cannot happen yet.
  Per-service windows and an identity set sized to disk retention are N2.
- **D-022 — What the 1,000,000-unit run counts.** Events ingested by the
  running app from the local replay fixture server at 1,000 events/s with
  10,000-event bursts; plus 1,000,000 headless index queries at package
  level for regressions; UI search p95 over 10,000 queries. The paired
  service is never the load target — load-testing Service Monitor is that
  project's job — so runs against a real instance are functional checks
  only.
- **D-023 — Supported macOS.** The current major macOS release and the
  previous one; the deployment target is the previous one. CI pins one Xcode
  version on a GitHub-hosted macOS runner, and every result records the
  versions it ran on.
- **D-024 — Milestone 0 starts with CI, a load scenario and a failure
  drill.** N0 ships the CI job (format lint, build, tests, the architecture
  checks), the package-level 1,000,000-event replay and the
  `disconnect-restart` drill before any UI exists. A development Mac with
  Xcode installed exists; pointing `xcode-select` at Xcode.app is an N0
  setup step, not a blocker. A status cell says *Done* only with named
  tests and an evidence path.
- **D-025 — The one reversible action: pause and resume one monitor.**
  Pausing is reversible (resume) and already exists in Service Monitor's
  API. The adapter reads the monitor's state first and sends nothing if it
  is already in the requested state, and after an uncertain response it
  reads back before anything else. It needs a token scope that allows
  pause and resume but not edit or delete, which Service Monitor does not
  offer yet (W-2). If no such scope ever exists, the app stays read-only —
  an acceptable outcome. Cost: N4 waits on another project's roadmap.

## Decisions made while building N0 (2026-11-16)

- **D-026 — The event list is an AppKit table, because it was measured.**
  The first shell drew the bounded history with a SwiftUI `List`. Under the
  fixture load (1,000 events/s plus 10,000-event bursts) one main-thread wait
  lasted 72.2 s, then 78.6 s in a second run, with a footprint peak of
  1.7–2.0 GB. `sample(1)` and then Instruments put every main-thread sample
  in SwiftUI's `OutlineListCoordinator.diffRows`, 78% of them in
  `NSHostingView.viewWillMove(toWindow:)`: the `List` builds and attaches a
  hosting view for every *inserted* row, visible or not, and the leaf time
  (observer removal, KVO bookkeeping) grows with the observers already on the
  window. Now an `NSTableView` with fixed row heights and `reloadData` builds
  only visible rows: same load, 0 hangs (watchdog and Instruments), worst
  wait 41–62 ms, peak 83–95 MB (`perf/results/README.md`, *App*). Given up: a pure
  SwiftUI list and multi-line rows in the list (a detail view shows a full
  line, N2). The old list stays behind `NW_EVENT_LIST=swiftui-list` so the
  profiling drill can be reproduced.
- **D-027 — The transport enforces its own hard deadline.** Every request
  has a timer that cancels it at the deadline and reports `timeout`; it is
  the deadline. URLSession's resource timeout stays as a backstop at twice
  the deadline. Why: during N0 a 2 s limit once took about 4 s on a
  response without `Content-Type` (URLSession held it for content
  sniffing); an independent attempt on Xcode 27.2 did not reproduce that
  stretch, so the observation is recorded as observed once, not as a
  reproduced bug. What proves the timer now: `testATrickledBodyHitsTheHardDeadline`
  (a body trickled under a 5 s idle timeout and a 0.4 s deadline) must end
  within 0.7 s; with the timer removed it ends at the backstop, 0.82 s, and
  fails. The poll deadline can be raised for measurement
  (`NW_POLL_DEADLINE_S`, 0.2–10 s); that never delays the stale label,
  which is derived from time (live only within one poll interval plus the
  1 s grace). Cost: one timer per request.
- **D-028 — N0 layout and toolchain.** One SwiftPM package at the repository
  root: pure library targets, the shell, and three executables (the app,
  `nw-replay`, `nw-fixture-server`); the fixtures target is never linked into
  the app (architecture check). Deployment target macOS 26 (D-023); CI on
  `macos-26` with Xcode 26.6 pinned, the checkout action pinned by SHA,
  `contents: read`. The Xcode project — signing, App Sandbox, the entitled
  data-protection Keychain, UI tests — is N1. Cost: until then the app is an
  unsigned SwiftPM executable, pairing comes from the process environment, and
  the Keychain round-trip test skips with `errSecMissingEntitlement` (stated,
  not passed).

## Open questions (still open)

These need the maintainer or another project; each is in the README's
*Blocked on* table.

- **Read-only token (W-1)** — a viewer token through Service Monitor's
  public API, built in Service Monitor under its own rules.
- **Pause/resume scope (W-2)** — the scoped token for the one action.
- **Promotion (W-3)** — the maintainer's decision after the comparison.
- **Apple Developer Program (W-4)** — needed only for signed distribution
  after promotion.
