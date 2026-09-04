# AGENTS.md — genai-approval

Guidance for coding agents (Grok, Codex, Claude, Cursor). Monorepo ops → `../../../../../CLAUDE.md` (trl-infra root).

## Identity

Approval-flow companion to the GenAI libs family (`ai/genai-core`, `ai/genai`): human-in-the-loop gating for LLM actions. Internal to the Noizu GenAI family — additive-first API discipline.

## Stack & Commands

Elixir. `mix deps.get && mix compile`; `mix test`; `mix format`, `mix credo`.

## Universal Rules (compressed)

- **Trinity Protocol REQUIRED**: Orientation → Friction → Response (full text: monorepo `protocols/the-trinity-protocol.md`).
- **No shell in main thread** — delegate to taskers.
- **Worktrees**: all work on worktrees; `epic.<group>` consolidation branches off `develop`; squash-PR provenance into epics.
- MAIN checkout owns `deps/_build`; worktrees symlink deps (absolute path).
