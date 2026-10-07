# Threat Model (summary)

Condensed companion to [THREAT-MODEL.md](THREAT-MODEL.md). Library, not a
service — surface realized inside each host app.

**Boundaries**: agent → script input · operator → run commands · engine →
external MCP servers (outbound, credentialed) · engine → DETS file ·
engine → agent (result).

**Register counts**: 11 entries — 7 mitigated, 3 partial, 1 accepted.

**Load-bearing mitigations**: data-only AST / no eval / no atoms from input;
size+step caps and run budgets; inline auth literals rejected; default-deny
permission resolution (block > allow, scope narrowing); HEEx-escaped
rendering; tool annotations untrusted.

**Partial (host responsibility by design)**:
- T-006 endpoint-origin pinning (SSRF) — hosts use `:transport` overrides
- T-007 DETS file integrity — host path ownership
- T-011 credential exposure to hostile endpoints — follows from T-006

**Accepted**: T-008 agents see approved outputs/notes/diffs by design.
