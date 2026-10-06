# Threat Model

## Overview

`genai_approval` is an **embedded library**, not a deployed service: its
attack surface is realized inside each host application. Assets: operator
credentials (resolved via `Host.resolve_credential/2`), permission grants
(ETS/DETS rule stores), and the operator's attention (each approval is a
privileged human action). Trust boundaries: **agent → script input**,
**operator → run commands**, **engine → external MCP servers** (outbound),
**engine → disk** (DETS store), **engine → agent** (result contract).

Grounding: [PROJ-ARCH.md](PROJ-ARCH.md) (components, security invariants) and
[arch/permissions.md](arch/permissions.md), [arch/mcp.md](arch/mcp.md),
[arch/ui.md](arch/ui.md). Code map: [PROJ-LAYOUT.md](PROJ-LAYOUT.md).

## Attack Surface

```mermaid
graph LR
    AG[Agent, untrusted script author] --|script text + vars| L[Load: lexer/parser/static checks]
    L --> R[Runner GenServer]
    OP[Operator] --|commands: step/next/edit/halt/grant| R
    R --> EX[Executors: Local / MCP]
    EX --|credentialed calls| EXT[External MCP servers]
    H[Host app] --|resolve_credential| R
    R --> DS[(DETS rule file)]
    R --|§9 result: outputs, notes, diffs| AG
    R --|events/snapshot, HEEx-escaped| UI[LiveView / Host surface]
```

## Vulnerability Register

| ID | Severity | STRIDE | Component | Status |
|----|----------|--------|-----------|--------|
| T-001 | High | Tampering / EoP | Script input | Mitigated — data-only AST, no eval, no atoms from input (PRD §11) |
| T-002 | Medium | DoS | Script input, runner | Mitigated — size/step caps at load; per-step/wall-clock/idle budgets; no loops or recursion |
| T-003 | High | Info disclosure | Endpoint preamble | Mitigated — inline auth literals are parse errors (`auth_literal`); credentials by reference only |
| T-004 | High | EoP | Permission engine | Mitigated — default-deny, normative resolution (block > allow, scope narrowing); lazy expiry pruning |
| T-005 | Medium | Tampering (XSS) | Render / LiveView | Mitigated — all script/operator content HEEx-interpolated; covered by tests |
| T-006 | High | Spoofing / SSRF | Script-declared endpoint URLs | **Partial** — engine does not pin origins; hosts must allowlist via `:transport` overrides (S4, [arch/mcp.md](arch/mcp.md)) — host responsibility |
| T-007 | Low | Tampering | DETS rule store | **Partial** — local file; no integrity protection beyond OS perms; host must restrict path ownership |
| T-008 | Low | Info disclosure | Result contract | **Accepted** — agents see outputs/notes/diffs by design; operator approves what is returned |
| T-009 | Low | Spoofing | MCP tool annotations | Mitigated — `describe/2` annotations treated as untrusted hints (S10) |
| T-010 | Medium | Repudiation | Grants | Mitigated — rules record `granted_by`/`granted_at`/`reason`; hosts supply subject identity |
| T-011 | Medium | Info disclosure | Outbound MCP credentials | **Partial** — credentials injected host-side; a hostile endpoint URL receiving them depends on T-006 pinning |

## Mitigation Coverage

7 mitigated · 3 partial · 1 accepted. The partial items (T-006, T-007, T-011)
are all **host-integration responsibilities** by design — document them in
each embedding app's own threat model; this library provides the mechanisms
(transport overrides, store behaviour, credential reference indirection).

## Residual Risk

The library trusts the host for endpoint-origin pinning, DETS file
protection, and operator identity. Within the engine, bounded-by-construction
parsing and default-deny permissions are the load-bearing controls; any
weakening of the static checks (e.g. raising caps) should re-open this model.
