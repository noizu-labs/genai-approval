# GenAI Approval

Interactive approval scripts for agents — a GenAI-ecosystem service.

An agent submits a small, deliberately **non-Turing-complete** script:
an endpoint preamble (credential *references*, never secrets), typed
variables, steps with conditional logic, and declared outputs. A human then
drives the run call-by-call — **step / next / run-all / edit / halt** — with
breakpoints, per-step permission gating, and scoped **allow/block command
rules** ("allow this session", "allow for the next hour", "block always").
The structured result (per-step outcomes, notes, edit diffs, outputs, halt
reason, grants) returns to the calling agent.

Design/PRD: `project-management/PRDs/genai-interactive-approval-scripts.md`
in the Noizu master repo.

## Documentation

| Doc | Contents |
|---|---|
| [`docs/arch/overview.md`](docs/arch/overview.md) | Component map, supervision, security invariants, milestone status |
| [`docs/arch/script-format.md`](docs/arch/script-format.md) | The script language: sections, grammar, hard rules, error codes, AST |
| [`docs/arch/runner.md`](docs/arch/runner.md) | Run state machine, commands, budgets, events, result contract |
| [`docs/arch/permissions.md`](docs/arch/permissions.md) | Rule model, normative resolution order, stores, runner gating |
| [`docs/arch/ui.md`](docs/arch/ui.md) | Rendering model, Host behaviour, LiveView reference UI, escaping |

## Status

**M1 — grammar + engine ✅**

- Handlebars-style grammar: `{{#endpoint}}` / `{{#vars}}` / `{{#step}}` /
  `{{#if}} {{else}}` / `{{#unless}}` / `{{#outputs}}`, expressions with
  `and/or/not`, comparisons, dotted paths, `call(...)`
- Hand-rolled lexer + recursive-descent parser; machine-readable rejection
  codes with line/column; static checks (undeclared vars/endpoints, pure
  conditions, no inline secrets, size/step caps)
- Steppable runner (GenServer): breakpoints, confirm steps, retry/skip,
  arg + variable edits, budgets (per-step timeout, wall clock, idle),
  event stream with replay ring, PRD §9 result contract
- Permission engine: `endpoint:command` glob rules, normative resolution
  (specificity → block>allow → narrower scope; default-ask), ETS store,
  time-boxed grants
- Executor behaviour + Local adapter (native handlers)

**M2 — session surface + LiveView reference UI ✅**

- Multi-subscriber event stream + `snapshot/1` for UIs
- `GenAI.Approval.Render` — shared rendering model: tolerant syntax
  highlighter (never raises), source lines annotated with step ranges /
  breakpoints / current & dimmed branches, navbar affordances
- `GenAI.Approval.Host` behaviour for non-web hosts (voice, TUI)
- `GenAI.Approval.Live.RunView` — embeddable LiveView (optional
  `phoenix_live_view ~> 1.1` dep): highlighted source with breakpoint
  gutter, step chips, permission prompt (approve / allow / block × scope),
  navbar step · next · run-all · retry/skip · halt + reason, notes,
  outputs panel; all content escaped (XSS-tested)

Embed it with:

```elixir
live_render(conn, GenAI.Approval.Live.RunView, session: %{"run_id" => run_id})
```

Next: M3 durable permission store, M4 MCP executor (`noizu_mcp`) +
`submit_approval_script` tool, M5 Hologram UI +
`com.noizu/approval-scripts` extension draft.

## Quick taste

```elixir
source = """
{{#endpoint "local"}} transport = "local" {{/endpoint}}
{{#vars}} n : number = 21 {{/vars}}
{{#step "Double it" confirm="really double"}}
  {{assign result = call("local", "math.double", n=n)}}
{{/step}}
{{#outputs}} answer = result.value {{/outputs}}
"""

{:ok, script} = GenAI.Approval.load(source)

{:ok, run} =
  GenAI.Approval.start_run(script,
    executors: %{
      "local" => {GenAI.Approval.Executor.Local,
                  %{"math.double" => fn %{"n" => n}, _ctx -> {:ok, %{"value" => n * 2}} end}}
    },
    subscriber: self(),
    permission: [store: {GenAI.Approval.Permission.Store.ETS, GenAI.Approval.PermissionStore},
                 subject: "keith", session_id: "sess-1"]
  )

:ok = GenAI.Approval.command(run, :run_all)
# confirm step parks the run:
# {:genai_approval, _, %{type: :permission_required, confirm: "really double"}}
:ok = GenAI.Approval.command(run, :approve)
{:ok, %{status: :completed, outputs: %{"answer" => 42}}} = GenAI.Approval.await(run)
```

## Tests

```
mix test   # 90 tests: parser golden/rejection/property, runner state machine,
           # budgets, failure paths, permission matrix, store, runner gating,
           # LiveView interaction + escaping (LiveViewTest)
```
