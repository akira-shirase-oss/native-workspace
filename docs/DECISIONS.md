# Decisions

Deliberate choices seeded by the guide, newest last. D-NNN numbering is
project-local, continuing the workspace convention. Each is a real
trade-off — what was given up is stated, not just what was chosen.

- **D-001 — Optional track, honestly labeled.** The guide marks itself
  OPTIONAL CONCEPT. These documents are a planning basis: no code, no
  device purchase, no schedule commitment is implied. The cost of honesty
  here is that the project may never build — that is an acceptable
  recorded outcome, not a failure to hide.
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
  an unsafe command" is answered structurally by the allowlist, not by
  prompt engineering.
- **D-010 — Signing, updates and permissions are product surface.** Signed
  distribution with documented update behavior is part of the feature
  set, not a release-day chore: updates must preserve compatible local
  state, credential revocation must demand renewed authority, and a
  rollback/diagnostic route must exist. Given up: informal unsigned
  distribution during development. Bought: the fourth required failure
  case is testable from N1 onward.
