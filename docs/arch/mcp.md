# MCP Integration (M4)

Two directions, both optional (`{:noizu_mcp, "~> 0.1", optional: true}` —
the engine works without it):

1. **Outbound** — `GenAI.Approval.Executor.MCP`: script steps execute
   against MCP servers.
2. **Inbound** — `GenAI.Approval.MCP.SubmitApprovalScript`: agents submit
   scripts through a standard MCP tool (the PRD §10 v1 interop surface).

## Outbound — the MCP executor

`{Executor.MCP, config}` per endpoint alias. `prepare/2` starts one
`Noizu.MCP.Client` per declared endpoint under
`GenAI.Approval.ClientSupervisor` (`restart: :temporary`), waits for the
handshake, and caches `tools/list` for `describe/2`. The runner closes all
executors exactly once when the run reaches a terminal state (R6.7).

Config keys:

| Key | Meaning |
|---|---|
| `:transport` | Explicit `Noizu.MCP.Client` transport tuple — overrides the script declaration. Required for stdio (commands are host config, never script input); used with `{:test, server: Mod}` in tests |
| `:credentials` | `%{"id" => {StrategyMod, opts}}` or 1-arity fun — resolves preamble `credential("id")` refs to client auth (e.g. `Noizu.MCP.Auth.Static` / `Noizu.MCP.Auth.OAuth`) |
| `:client_opts` | Extra client options (`:handler`, `:client_info`, `:request_timeout`) |
| `:ready_timeout` / `:call_timeout` | Handshake wait (10 s) / per tool call |

Script transport mapping: `"streamable_http"` → `{:streamable_http, url:
<declared>, auth: <resolved>}`. Unknown credentials, missing URLs, and
unsupported transports fail at `start_run` — before any client spawns (S4:
pin/allowlist endpoint origins in host config via `:transport` overrides).

Results: tool `structuredContent` becomes the call result (fallback: joined
text blocks under `"text"`); an `isError` tool result becomes a **step
failure** (`{:tool_error, text}`) — pause/retry/skip, never a runner crash.
Tool annotations surfaced by `describe/2` are untrusted hints (S10).

## Inbound — `submit_approval_script`

Register on any `Noizu.MCP.Server`:

```elixir
tool GenAI.Approval.MCP.SubmitApprovalScript
```

Input: `{script, variables?, timeout_ms?}` (raw JSON schema). Flow:

```
agent call ──▶ load (reject w/ line/col errors as isError result)
           ──▶ SubmitHost.run_options(script, meta)   # host maps endpoints→executors,
           ──▶ start_run                              # store/subject/session, budgets
           ──▶ SubmitHost.on_run(run, run_id, meta)   # host mounts UI / pings operator
           ──▶ PARK until run terminates (Inspector-style parked call)
           ──▶ sanitized §9 result as structuredContent
```

The host side is the `GenAI.Approval.SubmitHost` behaviour, configured via
`config :genai_approval, :submit_host, MyApp.ApprovalHost`. Refusals from
`run_options/2` surface as tool execution errors. If the caller's
`timeout_ms` expires first, the tool halts the run (`"submission timeout"`)
so nothing dangles.

`GenAI.Approval.Result.sanitize/1` makes the §9 result JSON-safe: string
keys, ISO-8601 datetimes, atoms→strings, tuples/pids inspected.

## Testing

`test/support/mcp_fixtures.ex` defines in-VM fixture servers (Alpha/Beta +
an ApprovalServer carrying the submit tool) wired via noizu_mcp's
`{:test, server: Mod}` transport — full wire boundary, no network.
`executor/mcp_test.exs` covers AC14 (one script → two servers, client
teardown) and AC16 (credential/transport rejection at start);
`mcp/submit_tool_test.exs` covers AC19 (agent submits → operator drives →
agent receives result; halt + notes; rejection; host refusal).

## Not yet implemented (v1 leftovers)

- Elicitation fallback for plain-MCP operator hosts (AC20)
- Server-side permission backstop in `noizu_mcp` (PRD §8.5 companion change)
- `com.noizu/approval-scripts` protocol extension (M5, PRD §10 v2)
