# Native Developer Workspace

> **Status — optional.** The guide marks this an OPTIONAL CONCEPT. A
> time-boxed, read-only exploration (N0–N2) may start now; it is not a
> product commitment and must not slow the active products. The concept
> becomes an active project only if the promotion gate after N2 passes
> (D-011). If it never passes, the project honestly stays a concept.

A macOS-native workbench for the portfolio's own services — Service
Monitor first, later the durable workflow runner, JavaScript-runtime
executions and Colophon release receipts. The first usefulness must come
from one reliable investigation workflow: connect an authorized service,
inspect status and bounded log history, select a failed operation, review
evidence and a proposed action, authorize, observe the result. Swift +
SwiftUI with AppKit where appropriate; the Rust services stay
authoritative — the desktop is a client, never a bypass, and the service's
token scope, not the app, is the security boundary. Read-only first; the
single permitted reversible action arrives only after promotion.

## Blocked on

Exploration (N0–N2) is not blocked. These need the maintainer or another
project:

| # | Needed | From | Blocks |
|---|---|---|---|
| W-1 | A read-only (viewer) token issued through Service Monitor's public API. Today it has one admin bearer token; per-workspace tokens and a viewer role are planned in its accounts milestone | Service Monitor | pairing with any non-loopback endpoint; the first signed release (N5). Exploration uses a local instance under a development-only exception (D-015) |
| W-2 | A Service Monitor token scope limited to one reversible action (pause/resume a monitor, D-025) | Service Monitor | N4 |
| W-3 | The promotion decision after the pre-registered comparison (D-012) | the maintainer | N3–N5 |
| W-4 | Apple Developer Program membership for Developer ID signing and notarization (D-019) | the maintainer | N5 distribution (development signing needs none) |

## Documents

- `docs/END_GOAL.md` — what done means, scope, invariants, the four
  required failure cases with their tests and pass conditions, the
  promotion gate and the release gate
- `docs/ARCHITECTURE.md` — components, sources of truth, data paths,
  planned layout, consistency story
- `docs/ROADMAP.md` — exploration N0 spine → N1 shell → N2 read-only value
  → promotion review → N3 assistance → N4 one controlled action → N5 signed
  release
- `docs/DECISIONS.md` — native-only UI, service authority, read-only first,
  no FFI before measured need, bounded retention with visible gaps
  (D-001–D-010), the decisions made before code (D-011–D-025) and the
  questions still open

Contract: the engineering guide `10_Native_Developer_Workspace.docx` (kept
in the maintainer's workspace under `docs/Project_Guides/`, not in this
repository).

**What counts as done:** first, the promotion gate — the read-only
investigation workflow beats the existing terminal and web interface on a
pre-registered comparison, with failure cases 1, 2 and the revocation half
of 4 proven and the 1,000,000-event run recorded (machine + commit). Then,
only if promoted, the release gate: all four failure cases proven and a
signed, notarized build with documented update behavior.
