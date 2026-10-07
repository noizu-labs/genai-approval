# Project Architecture (summary)

Condensed companion to [PROJ-ARCH.md](PROJ-ARCH.md).

**What**: Elixir library for human-in-the-loop approval of agent actions.
Agents submit a non-Turing-complete script; humans drive the run
(step/next/run-all/edit/halt) with permission gating; a structured result
returns to the agent.

**Shape**: pure compile pipeline (lexer → parser → static checks → AST) →
per-run supervised Runner GenServer → pluggable executors (Local, MCP) and
permission stores (ETS, DETS) → optional LiveView reference UI.

**Key invariants**: no eval (data-only AST); no atoms from input; bounded by
construction (size/step caps, timeouts); credentials by reference only
(inline secrets are parse errors); default-deny permissions; escaped rendering.

**Stack**: Elixir ~1.18+/OTP 29; `telemetry`, `jason`; optional
`phoenix_live_view`, `noizu_mcp`.

**Detail docs**: `arch/overview.md` (components, supervision, invariants),
`arch/script-format.md`, `arch/runner.md`, `arch/permissions.md`, `arch/ui.md`,
`arch/mcp.md`. Structure map: `PROJ-LAYOUT.md`.
