# UI Surface — Rendering Model, Host Behaviour, LiveView

PRD §7: the engine is UI-agnostic; hosts drive runs through events +
commands. Two reference UIs are planned (LiveView ✅ M2, Hologram — M5),
both consuming the **same rendering model** so they stay in feature parity.

## Data flow

```
Runner ──events──▶ subscriber processes (LiveView, test, voice host, …)
Runner ──snapshot─▶ Render.model/1 ──▶ UI
UI ──phx events──▶ GenAI.Approval.command/2 ──▶ Runner
```

The LiveView re-snapshots on every run event — state lives in the runner,
never in the UI. Any number of subscribers can watch one run (operator UI +
audit tap + test harness).

## Rendering model — `GenAI.Approval.Render`

- `highlight/1` — a **tolerant** token classifier (independent of the strict
  lexer): source → lines of `{class, text}` spans, classes
  `cmt tag kw str num ident punct ws`. It never raises, even on invalid or
  hostile input — UIs may need to display a script that failed to load.
- `model/1` — takes `GenAI.Approval.snapshot/1` and produces:
  - `lines` — highlighted lines annotated with `step` (id whose
    `line..end_line` range covers it), `step_start`, `bp` (breakpoint dot),
    `current` (pending step), `dim` (steps in untaken branches / not reached)
  - `steps` — chips: id, title, status
    (`waiting pending completed failed skipped declined not_reached`),
    breakpoint flag, per-step result
  - `can` — navbar affordances (`step next run_all halt retry skip approve`)
    derived from run status, so UIs never re-implement state-machine logic
  - passthrough: `awaiting` (permission prompt payload incl. `confirm`
    phrase), `branches`, `notes`, `edits`, `grants`, `halt`, `result`

## Host behaviour — `GenAI.Approval.Host`

For non-LiveView hosts (voice agents, TUIs): implement `present/2` (run is
ready), `on_event/3` (stream), and optionally `resolve_credential/2`
(preamble `credential("id")` → executor auth config). Commands flow back via
`GenAI.Approval.command/2`. The engine enforces `confirm` phrases and
grant-scope acknowledgment regardless of presentation, so a voice surface
cannot bypass them (R7.4).

## LiveView reference UI — `GenAI.Approval.Live.RunView`

Compiled only when `phoenix_live_view` (optional dep, `~> 1.1`) is present.

```elixir
live_render(conn, GenAI.Approval.Live.RunView, session: %{"run_id" => run_id})
```

Features: syntax-highlighted source with line-number gutter and clickable
breakpoint dots; current-step highlight; untaken branches dimmed; step chips;
permission prompt with **Approve once / Allow (session · 1 hour · always) /
Block (session · always) / Decline** (allow buttons hidden on `confirm`
steps); navbar **Step · Next · Run All · Retry · Skip · Halt (+ reason)**;
notes; outputs + halt panel on terminal. Styling is a self-contained scoped
`<style>` block — no asset pipeline required.

**Escaping (S9 / AC23):** every piece of script and operator content renders
through HEEx interpolation, so hostile titles/notes render inert. Covered by
tests in `test/genai/approval/live/run_view_test.exs`.

## Testing infrastructure

`test/support/endpoint.ex` is a minimal `Phoenix.Endpoint` (config in
`config/config.exs`, test env only) started from `test_helper.exs`;
LiveView tests use `live_isolated/3` — no router or real server. LiveView
1.2 requires `lazy_html` as the test-only DOM parser.
