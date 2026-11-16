# Native Developer Workspace

> **Status — optional track, planning only.** Guide 10 is marked OPTIONAL
> CONCEPT. This directory holds documents, not a product commitment: no
> code exists, no device purchase is confirmed, and nothing here weakens or
> delays the active projects. Promotion to an active project happens only
> through the ship gate in `docs/END_GOAL.md`.

A macOS-native workbench for the portfolio's own services — Service
Monitor, Durable Workflow Runner, and later jsrt executions and Colophon
release receipts. The first usefulness must come from one reliable
investigation workflow: connect an authorized service, inspect status and
bounded log history, select a failed operation, review evidence and a
proposed action, authorize, observe the result. Swift + SwiftUI with AppKit
where appropriate; the Rust services stay authoritative — the desktop is a
client, never a bypass. Read-only first; the single permitted reversible
action arrives only after the read-only console is useful.

- `docs/END_GOAL.md` — what done means, scope, invariants, the four required
  failure cases, the promotion gate
- `docs/ARCHITECTURE.md` — components, sources of truth, data paths,
  planned layout, consistency story
- `docs/ROADMAP.md` — N0 environment → N1 shell → N2 read-only →
  N3 assistance → N4 controlled action, each with its proof gate
- `docs/DECISIONS.md` — native-only UI, service authority, read-only first,
  no FFI before measured need, bounded retention with visible gaps
- `../../docs/Project_Guides/10_Native_Developer_Workspace.docx` — the contract
  (workspace root `Project_Guides/`)

**What counts as done:** the promotion gate — one native investigation
workflow demonstrated *clearly more useful* than the existing terminal or
web interface on the same task, with the four failure cases proven and the
workload evidence recorded (machine + commit). If the gate is never met,
this project honestly stays a concept — that is an acceptable outcome.
