# Permission Engine

Scoped allow/block rules for commands (PRD §8) — the mechanism that lets
"approve every call" collapse into policy: *allow this session*, *allow for
the next hour*, *block always*.

## Rule model

```elixir
%GenAI.Approval.Permission.Rule{
  pattern:    "github:issues.*",   # "endpoint:command", glob on the command side
  effect:     :allow | :block,
  scope:      :call | :session | {:until, DateTime.t()} | :always,
  subject:    "user-id" | nil,     # nil = any subject
  session_id: "sess" | nil,        # set for :session scope
  ...
}
```

Pattern matching:

- Endpoint side: exact or `*`.
- Command side: exact (`issues.create`), glob prefix (`issues.*` — matches
  `issues`, `issues.create`, `issues.comment.reply`), or `*`.
- "Allow for the next hour" is stored as an absolute `{:until, now+3600}` —
  there are no ambient "current hour" semantics (R8.1).

## Resolution (normative, PRD §8.2)

`Permission.decide(rules, endpoint, command, now)` → `{:allow, rule} |
{:block, rule} | :ask`

1. **Specificity first** — exact command ≫ longer glob ≫ shorter glob ≫ `*`;
   command specificity dominates endpoint specificity
   (`github:issues.create` > `github:issues.*` > `github:*` > `*:*`).
2. **Block beats allow** at equal specificity.
3. **Narrower scope beats wider** at equal specificity + effect
   (`:call` > `:session` > `{:until,_}` > `:always`).
4. **No match ⇒ `:ask`** — default-deny, never default-allow.
5. Expired `{:until, t}` rules never match; stores prune them lazily on read.

The full matrix lives in `test/genai/approval/permission_test.exs` (22+
table-driven cases) — treat it as the executable spec.

## Runner integration

- The gate runs **before every step execution**, including under `run_all`.
  A step gates on *all* of its statically-extracted `{endpoint, command}`
  pairs: any block ⇒ block; any unmatched ⇒ ask.
- A `:block` outcome auto-halts the run with `blocked_by_policy` and the
  firing rule id (R8.2) — `run_all` stops right there.
- `:ask` parks the run in `awaiting_permission` and emits
  `permission_required`; the operator answers with `:approve` (one-shot),
  `:decline`, or `{:grant, effect, scope}` which writes a rule and re-gates.
- `confirm="phrase"` steps bypass rules entirely — they always ask.
- `:call`-scoped grants are transient by design; `Store.ETS.put/2` refuses
  to persist them.

## Stores

`GenAI.Approval.Permission.Store` behaviour (`put / revoke / rules / list`),
addressed as `{module, ref}`. `rules/3` filters by subject and session and
prunes expired rows. Implementations:

- **`Store.ETS`** (default) — in-memory; named public table owned by a
  GenServer (`GenAI.Approval.PermissionStore` under the app supervisor), or
  caller-owned anonymous tables via `ETS.new/0` (tests).
- **`Store.DETS`** (M3, durable) — disk-persistent, survives restarts;
  writes are `:dets.sync`ed so a crash cannot lose an `always`/`block`
  grant. Start with `{Store.DETS, name: MyStore, path: "…/rules.dets"}` and
  address as `{Store.DETS, MyStore}`.

One conformance suite runs against every implementation
(`test/genai/approval/permission/store_conformance_test.exs`) — add new
stores there. For multi-node or cross-app per-user rules, implement the
behaviour over shared storage (e.g. a `noizu_labs_entities` entity); the
behaviour is the seam.

## Server-side backstop (companion work)

Per the PRD's both-layers decision, `noizu_mcp` grows a policy hook in
`Features.Tools.dispatch/4` so a compromised or non-Noizu client still can't
execute blocked commands. Specified in PRD §8.5; delivered with the M4 MCP
work, not in this library.
