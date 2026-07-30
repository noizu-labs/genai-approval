# Script Format

Handlebars-*style* syntax (mustache-delimited blocks) chosen for LLM
familiarity — but parsed by our own lexer + recursive-descent parser into a
steppable AST. Off-the-shelf template engines render in one pass and cannot
pause at a call site, honor breakpoints, or gate on permissions.

A script has four ordered sections:

```handlebars
{{!-- 1. preamble: endpoint declarations --}}
{{#endpoint "github"}}
  transport = "streamable_http"
  url       = "https://mcp.github.internal/mcp"
  auth      = credential("github-bot")   {{!-- host-side reference, never a secret --}}
{{/endpoint}}

{{!-- 2. typed variables --}}
{{#vars}}
  repo   : string  = "noizu/genai_core"
  urgent : boolean = false
  issue  : object?                        {{!-- ? marks nullable --}}
{{/vars}}

{{!-- 3. body: steps + conditionals --}}
{{#step "Find the issue" breakpoint=true}}
  {{assign issue = call("github", "issues.search", repo=repo, state="open")}}
{{/step}}

{{#if issue}}
  {{#step "Comment" confirm="really comment"}}
    {{call "github" "issues.comment" number=issue.number, body="Approved."}}
  {{/step}}
{{else}}
  {{#step "Create" optional=true}}
    {{assign issue = call("github", "issues.create", repo=repo)}}
  {{/step}}
{{/if}}

{{!-- 4. outputs: returned to the calling agent --}}
{{#outputs}}
  issue_number = issue.number
{{/outputs}}
```

## Grammar summary

- **Types**: `string number boolean object list`; `?` suffix = nullable.
- **Step attributes**: `breakpoint=true`, `confirm="phrase"`, `optional=true`,
  `note="..."`.
- **Statements** (inside steps only): `{{assign var = expr}}`,
  `{{call "endpoint" "command" name=expr, ...}}`.
- **Expressions**: literals (strings, numbers, booleans, `null`, lists),
  dotted variable paths (`issue.number` — lenient: dotting into `nil` yields
  `nil`), `call("endpoint", "command", name=expr, ...)`, comparisons
  (`== != < > <= >=`), `and` / `or` / `not`, parentheses.
- **Conditionals**: `{{#if expr}} ... {{else}} ... {{/if}}`,
  `{{#unless expr}} ... {{/unless}}` (no `else` in unless).
- **Comments**: `{{!-- ... --}}` and `{{! ... }}` anywhere.
- Truthiness is handlebars-style: only `false` and `null` are falsy.

## Hard rules (enforced at load)

| Rule | Error code |
|---|---|
| No loops / recursion / unknown blocks | `:unknown_block` |
| `call` statements only inside steps | `:stmt_outside_step` |
| Conditions are pure — no `call()` | `:call_in_condition` |
| Outputs are pure — no `call()` | `:call_in_outputs` |
| Endpoint aliases declared before use | `:undeclared_endpoint` |
| `auth` must be `credential("id")` | `:auth_literal` |
| Variables declared before use/assignment | `:undeclared_var` |
| Defaults must match declared type; `null` needs `?` | `:type_mismatch` |
| Size cap (64 KiB) / step cap (50), host-configurable | `:script_too_large` / `:too_many_steps` |

Every error carries `code`, `message`, `line`, `column`. Parse errors return a
single-element list; static checks report **all** violations. Nothing partial
is ever presented as runnable (R5.8).

The maximum number of executable steps is statically known at parse time —
a security property, not a limitation: an approval script's work is bounded
by construction.

## AST

`GenAI.Approval.load/2` → `%GenAI.Approval.Script{endpoints, vars, body,
outputs, steps, source}`. `steps` is the document-order flattening (ids
`"s1"`, `"s2"`, … including both branch arms). Steps and conditionals carry
`line`/`end_line` (and `else_line`) so UIs can map source regions to run
state. Expressions are data tuples (`{:lit, v}`, `{:var, path}`, `{:op, ...}`,
`{:call, ...}`) — never code.
