# Architecture

Architecture of the exploration. N0 (the spine) exists as code; the rows
marked *after promotion* and the pieces named for N1/N2 are still plans.
Names were fixed at N0 (see *Layout* below).

## Sources of truth

1. **The paired services are the only authority** — status, log history,
   failure detail and action results are service state, read and written
   through the service's own versioned HTTP API. The app never edits
   service state directly.
2. **The service's token scope is the security boundary.** What the app
   may do is what the paired token lets the service accept. The app's
   allowlist and confirmation sheets are defense in depth (D-014).
3. **The Keychain is the only credential store.** Tokens are stored per
   service at pairing with this-device-only accessibility; nothing
   secret-shaped lives in preferences, logs or the index.
4. **The local index is disposable.** The bounded search index (redacted
   text, D-017), cached views and preferences are rebuilt or re-fetched;
   losing them loses no truth. Their lifecycle is explicit: what is kept,
   for how long, how it is wiped.
5. **The local audit record of authorized actions is durable** (D-020).
   Services with their own audit keep the authoritative half.

## Components

| Component | Role |
|---|---|
| App shell (SwiftUI + AppKit) | Navigation, menus, shortcuts, accessibility, windows. Native controls only — no WebKit anywhere (CI checks). |
| Connection/session model | Typed pairing per service: endpoint, protocol version, granted scopes as reported by the service (or "unknown, treat as admin"), token in Keychain. Owns connect, disconnect, stale and revoked states with timestamps. |
| Service adapters | One per service; first Service Monitor (D-013). Versioned HTTP with bounded polling; reconnect with backoff; stale labeling. The read-only build can construct only `GET` requests (a test proves it). |
| Text sanitizer | Turns untrusted log text into inert display text: terminal escapes, control characters and bidi overrides become visible escapes (D-016). |
| Redactor | Removes secret-shaped text before it is indexed, exported or sent to an AI provider (D-017). Tested against a corpus. |
| Event ingest | Bounded queue, batching into UI updates, gap markers on overflow (D-021) — the 10,000-burst case lives here. |
| Local index | Bounded search index over retained, redacted history plus preferences. Disposable; rebuilt on launch. |
| Assistance adapter (after promotion) | Optional AI provider: summarizes *selected, redacted, previewed* evidence; output marked advisory; every proposed action checked against the capability allowlist. App fully functional with no provider. |
| Action pipeline (after promotion) | Propose → display exact parameters → explicit confirmation → read current state → submit once with an idempotency key → audit → verify the post-state from the service. One reversible command in total. |

## Paths

**Pair:** the user names a service and endpoint → the token goes into the
Keychain → capability handshake (protocol version, granted scopes if the
service reports them) → the service appears in the sidebar. A token whose
scope the service cannot report is treated as admin-class and may only be
paired with a loopback endpoint (D-015). Unpairing deletes the Keychain
item and wipes that service's local index.

**Inspect:** the adapter polls the service's paginated reads at a bounded
interval (2 s while visible, backing off while hidden) → responses pass the
sanitizer and the redactor → the bounded index → search and history views
read the index → a disconnect marks every view from that service "stale
since T"; reconnect resumes without re-pairing and without re-sending any
authorized action. A 401 marks the service "authority revoked" and stops
polling.

**Investigate:** select a failed operation → gather its evidence bundle →
(optional, after promotion) the assistance adapter shows exactly what it
would send, then summarizes → a proposed action is rendered with exact
parameters; an allowlist refusal is shown as a refusal, not silence.

**Act (after promotion):** confirmation sheet with exact parameters →
authorize → the adapter reads the current state and sends nothing if the
target is already in the requested state → otherwise submits once under an
idempotency key → audit record → the result and post-state are verified
from the service. A disconnect mid-action shows `uncertain`, then reads
back before anything else — never a blind retry.

**Burst:** ingest admits into the bounded queue → overflow drops and counts
into an open gap marker (count and time range) → updates batch onto the
main actor at most every 100 ms → long lists virtualize.

## Consistency story

The service wins every disagreement; the app only ever *displays* and
*submits*. Freshness is a label on every view (live / stale since T /
authority revoked), not a property of the data. Authorized actions are made
safe against the client's own failures by state read-back and idempotency
keys — the honest model is at-most-once *effect*, with `uncertain` states
reconciled, matching how the services themselves treat external calls.
The local index can lie by being behind; it can never lie by being ahead,
and it is never authoritative.

## Layout (fixed at N0)

One SwiftPM package at the repository root (`Package.swift`, deployment
target macOS 26, D-023). Pure logic is in library targets, so `swift test`
covers it without an app bundle.

```
Sources/
  NWCore/          pure: event model, InertText (D-016), bounded IngestQueue
                   with gap markers (D-021), EventStore (bounded, segmented
                   JSON Lines, acknowledged = synced), ConnectionTracker
                   (freshness, backoff), main-actor view models, IngestPump,
                   measurement helpers (watchdog, histogram, memory)
  NWCredentials/   SecretToken (unprintable), Keychain (this device only)
                   and process-environment sources
  NWAdapters/      ReadOnlyHTTP.swift — the only place a URLRequest or
                   URLSession exists: GET-only, deadline, size cap,
                   same-origin redirects; Service Monitor and Durable
                   Runner adapters; ServiceConnection (polling, backoff,
                   stop on 401)
  NWFixtures/      loopback fixture HTTP server (killable, records methods)
                   and the services' read-API emulators — never linked
                   into the app (architecture check)
  NWShell/         SwiftUI shell + AppKit event table; AppModel wiring;
                   measurement mode
  NWApp/           the app executable (`NativeWorkspace`)
  NWReplay/        `nw-replay`, the headless 1,000,000-event replay
  NWFixtureServer/ `nw-fixture-server`, the local replay fixture server
Tests/             XCTest per target, including both disconnect-restart
                   drills (fixture server; real scratch services)
fixtures/          hostile-log-lines and the fixture index
perf/results/      replay, drill and app measurements (machine + commit)
scripts/           check.sh (what CI runs), arch-check.sh and its self-test,
                   replay.sh, drill-real-services.sh, measure-app.sh
docs/              this set
```

An Xcode app project (signing, App Sandbox, the entitled data-protection
Keychain, UI tests) arrives in N1; until then the app is a SwiftPM
executable, development-only and unsigned.

## Decisions and open questions

The questions this architecture used to leave open — first adapter,
transport, the first action, the audit format, the update mechanism, the
comparison method, the macOS matrix, device availability — are decided in
`DECISIONS.md` (D-011–D-025). What still needs the maintainer or another
project is in its *Open questions (still open)* and in the README's
*Blocked on* table.
