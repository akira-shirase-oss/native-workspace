# Roadmap

Step order follows the guide's build/break/measure contract: environment,
shell, read-only value, assistance, one controlled action — each with its
proof before the next starts. This entire track is **optional**: nothing
starts until the maintainer promotes it, and the promotion gate in
`END_GOAL.md` is itself the final step's exit review.

| Step | Builds | Proves | Status |
|---|---|---|---|
| **N0 — environment + profiling literacy** | Supported macOS + Xcode environment (recorded, not assumed — device availability is an open question); signed debug build; the learning drill: deliberately reproduce a UI stall, locate it in Instruments, verify the fix | A stall reproduced and fixed with committed before/after Instruments traces; Mac/OS/Xcode/build recorded as the evidence baseline | Planned — optional track |
| **N1 — native shell** | SwiftUI navigation, menus and shortcuts, accessibility baseline; the typed connection model: explicit pairing, scoped Keychain tokens, connect/disconnect/stale states | Connect to a real service through its own API; disconnect marks views stale-with-timestamp; XCTest + UI tests green; no webview anywhere in the shell | Planned — optional track |
| **N2 — read-only value** | First service adapter (Service Monitor *or* durable-runner — open question), bounded searchable history, reconnect without duplication | Failure cases 1+2: service restart shows stale + reconnects cleanly; the 10,000-event burst stays responsive with *visible* gaps; 10k-row search p95 measured against the 200 ms proposed target | Planned — optional track |
| **N3 — evidence-linked assistance** | Optional AI adapter over selected, redacted evidence; capability allowlist; provider-absent mode | Failure case 3: an unsafe proposal is refused by the allowlist and shown as refused; approval never widens scope; uncertainties visible in the summary; the app is fully useful with no provider configured | Planned — optional track |
| **N4 — one controlled action + gate review** | One reversible scoped command: exact-parameter confirmation, idempotency key, durable audit record, verified result | Failure case 4: app update + credential revocation preserve state, demand renewed authority, keep a diagnostic route; reconnect mid-action surfaces `uncertain`, never duplicates the effect; **the promotion gate is reviewed against recorded evidence** | Planned — optional track |

## Promotion gate

After N4's proofs: is one native workflow **clearly more useful** than the
existing terminal or web interface on the same investigation task? The
comparison method is fixed before the review (see open questions in
`ARCHITECTURE.md`). A "no" ends the track honestly — the evidence is kept,
the concept stays a concept.

## Later extensions (explicit contracts required)

Additional reversible actions, iOS, Linux/Windows native clients, an FFI
bridge to Rust service internals (only after a measured need, D-005), and
any AI capability beyond summarize-and-propose. Each gets its own contract
before work starts — including the first adapter's siblings (jsrt
executions, Colophon release receipts) which the guide names as the full
direction but not the first release.
