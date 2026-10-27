# AGENT-README

> Orientation for AI coding agents working in this repo. Human docs: README.md.

## Type

elixir-lib

## Purpose

Interactive approval scripts for agents: an agent submits a deliberately non-Turing-complete script (endpoint preambles with credential references, typed vars, conditional steps, declared outputs), a human drives the run call-by-call (step/next/run-all/edit/halt) with scoped allow/block permission rules, and the structured result returns to the calling agent.

## Stack

Elixir ~> 1.18 (telemetry, jason); optional deps: `phoenix_live_view ~> 1.1` (embeddable RunView reference UI) and `noizu_mcp ~> 0.5` (MCP executor); permission stores in ETS + DETS.

## Dev mode

```bash
mix deps.get && mix compile
```

## Ports / URLs

- none (library/CLI)

## Tests

```bash
mix test
```

## Gotchas

- LiveView and MCP are optional deps — the engine compiles without them; don't turn them into hard requirements.
- Additive-first API discipline: internal to the Noizu GenAI family (`genai-core`, `genai`).
- Embed the UI with `live_render(conn, GenAI.Approval.Live.RunView, session: %{"run_id" => run_id})`.
- Design/PRD lives in the master repo: `project-management/PRDs/genai-interactive-approval-scripts.md`.
