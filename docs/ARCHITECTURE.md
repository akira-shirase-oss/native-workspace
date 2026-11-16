# Architecture

Planned architecture — no code exists yet. Sources of truth and data paths
are contract-level; crate/package names are placeholders fixed at N0.

## Sources of truth

1. **The paired services are the only authority** — status, log history,
   failure detail and action results are service state, read and written
   through the service's own versioned API or permissioned IPC. The app
   never edits service state directly.
2. **The Keychain is the only credential store.** Tokens are scoped per
   service at pairing; nothing secrets-shaped lives in preferences, logs
   or the index.
3. **The local index is disposable.** The bounded search index, cached
   views and preferences are rebuilt or re-fetched; losing them loses no
   truth. Their lifecycle is explicit (what is kept, for how long, how it
   is wiped).
4. **The audit record of authorized actions is durable.** What the user
   confirmed, with which exact parameters, and what result came back is
   recorded locally; services with their own audit (e.g. Colophon) keep
   the authoritative half. The exact local format is an open question —
   decided at N4, not guessed now.

## Components

| Component | Role |
|---|---|
| App shell (SwiftUI + AppKit) | Navigation, menus, shortcuts, accessibility, windows. Native controls only — no webview-hosted UI. |
| Connection/session model | Typed pairing per service: scopes granted, endpoint, protocol version, token in Keychain. Owns connect/disconnect/stale state with timestamps. |
| Service adapters | One per service (first: Service Monitor *or* durable-runner — open question). Versioned HTTP or permissioned local IPC; reconnect with backoff; stale labeling. |
| Event ingest | Bounded queues, batching into UI updates, backpressure, gap markers on overflow — the 10k-burst case lives here. |
| Local index | Bounded search index over retained history plus preferences. Disposable; rebuilt on launch. |
| Assistance adapter | Optional AI provider: summarizes *selected, redacted* evidence; output marked advisory; every proposed action checked against the capability allowlist. App fully functional with no provider. |
| Action pipeline | Propose → display exact parameters → explicit confirmation → authorize with an idempotency key → audit → observe verified result. One reversible command total in the first release. |

## Paths

**Pair:** user names a service + endpoint → token with minimum scopes into
Keychain → capability handshake (protocol version, granted scopes) →
service appears in the sidebar. Unpairing revokes and wipes that service's
local index — the data lifecycle is per-service.

**Inspect:** adapter queries the service → responses fill the bounded
index → search/history views read the index → disconnect marks every view
from that service stale-with-timestamp; reconnect resumes without
re-pairing and without re-sending any authorized action.

**Investigate:** select a failed operation → gather its evidence bundle →
(optional) assistance adapter redacts and summarizes → proposed action
rendered with exact parameters; allowlist refusal shown as refusal, not
silence.

**Act:** confirmation sheet shows exact parameters → authorize → the
adapter submits once under an idempotency key → audit record → result and
post-state verified from the service, not assumed. Reconnect mid-action
surfaces `uncertain`, then reconciles against the service — it never
blindly retries.

**Burst:** ingest admits into bounded queues → dropped events become
explicit gap markers → updates batch onto the main actor → long lists
virtualize.

## Consistency story

The service wins every disagreement; the app only ever *displays* and
*submits*. Freshness is a label on every view (live / stale-since-T), not
a property of the data. Authorized actions are made safe against the
client's own failures by idempotency keys — the honest model is
at-most-once *effect* with `uncertain` states reconciled, matching how the
services themselves treat external calls. The local index can lie by
being behind; it can never lie by being ahead, and it is never
authoritative.

## Planned layout

```
app/             Xcode project: SwiftUI shell, AppKit pieces, UI tests
packages/        SwiftPM packages — connection model, service adapters,
                 ingest, local index, assistance, action pipeline
                 (pure logic stays SwiftPM so `swift test` covers it)
fixtures/        recorded service responses + event streams:
                 burst-10k, disconnect-mid-action, unsafe-proposal,
                 revoked-credential
perf/            workload drivers, Instruments traces, results/
                 (machine + OS + build + commit on every run)
docs/            this set; module docs added when code lands
```

## Open questions (the guide leaves these open — do not guess)

- **First adapter:** Service Monitor or durable-runner — the guide offers
  either. Chosen at N2 by whichever service's API best exercises the
  inspect/investigate workflow.
- **Transport per adapter:** versioned HTTP API vs permissioned local IPC.
  The guide permits both; decided per service when the adapter is built.
- **The first reversible action:** unspecified. Candidates are whatever the
  chosen service already exposes as scoped and reversible; fixed at N4.
- **Local audit format:** file format and retention for authorized-action
  records.
- **Update mechanism:** signed distribution is required; the mechanism
  (Sparkle-style, signed pkg, App Store) is undecided — "documented update
  behavior" is the contract, the vehicle is open.
- **Gate comparison method:** how "clearly more useful" is measured for
  the promotion gate — fixed before the N4 gate review.
- **Supported macOS matrix:** which releases the app tracks — set when a
  build exists.
- **Device availability:** macOS-first is the suggested boundary, not a
  confirmed device purchase; N0 cannot start without a supported
  Mac/Xcode environment.
