# Project Architecture

## Overview

`genai_approval` is an Elixir library for human-in-the-loop gating of agent
actions: an agent submits a small, non-Turing-complete **approval script**
(endpoint preamble, typed variables, steps with conditionals, declared
outputs); a human drives the run call-by-call — step / next / run-all /
edit / halt — with breakpoints, per-step permission gating, and scoped
allow/block command rules. The structured result (per-step outcomes, notes,
edit diffs, outputs, halt reason, grants) returns to the calling agent.

Architectural style: a **pure compile pipeline** (lexer → parser → static
checks → AST) feeding a **per-run supervised GenServer state machine**, with
pluggable executors (Local, MCP), pluggable permission stores (ETS, DETS),
and an optional LiveView reference UI. Optional deps (`phoenix_live_view`,
`noizu_mcp`) keep the core engine dependency-light.

## System Diagram

```mermaid
flowchart LR
    A[Agent] -- script source + vars --> C[Compile: Lexer → Parser → StaticChecks]
    C --> AST[%Script{} AST]
    AST --> R[Runner GenServer, one per run]
    R --> EX[Executor behaviour: Local / MCP]
    R --> P[Permission.decide]
    P --> ST[Store behaviour: ETS / DETS]
    R -- events/snapshot --> U[Render model → LiveView reference UI]
    OP[Operator] --> U
    R -- §9 result contract --> A
```

## Core Components

| Component | Purpose |
|-----------|---------|
| Compile pipeline | Lexer + recursive-descent parser + static checks → data-only AST |
| Runner | Steppable run state machine; budgets, breakpoints, edits, event ring |
| Executors | Local (native handlers) and MCP (`noizu_mcp`) step execution |
| Permissions | Glob-pattern allow/block rules, normative resolution, ETS/DETS stores |
| Surfaces | Render model, Host behaviour, LiveView reference UI |
| MCP tool | `submit_approval_script` + SubmitHost behaviour for agent submission |

→ *Components ↔ directories: see [PROJ-LAYOUT.md](PROJ-LAYOUT.md)*
→ *Module-by-module table: see [arch/overview.md](arch/overview.md)*

## Detailed Architecture

- [arch/overview.md](arch/overview.md) — component map, supervision, security invariants, milestone status
- [arch/script-format.md](arch/script-format.md) — script language: sections, grammar, hard rules, error codes, AST
- [arch/runner.md](arch/runner.md) — run state machine, commands, budgets, events, result contract
- [arch/permissions.md](arch/permissions.md) — rule model, resolution order, stores, runner gating
- [arch/ui.md](arch/ui.md) — rendering model, Host behaviour, LiveView reference UI, escaping
- [arch/mcp.md](arch/mcp.md) — MCP executor, `submit_approval_script` tool, SubmitHost behaviour

## Key Decisions

- **Non-Turing-complete by construction** — no loops/recursion; bounded work is a security property (PRD §11).
- **Data-only AST, no eval, no atoms from input** — scripts can never dispatch script-derived code.
- **Default-deny permissions** — no matching rule ⇒ ask the operator.
- **Optional heavy deps** — LiveView UI and MCP executor compile only when present; engine works standalone.
- **Crash containment** — steps run in supervised tasks; a failing handler is a step failure, never a runner crash.

## Technology Stack

Elixir ~1.18+ (OTP 29). Deps: `telemetry`, `jason`; optional:
`phoenix_live_view` (reference UI), `noizu_mcp` (MCP executor/tool);
dev/test: `lazy_html`, `stream_data`, `ex_doc`.
