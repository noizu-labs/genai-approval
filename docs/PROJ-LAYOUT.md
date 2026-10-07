# Project Layout

`genai_approval` — interactive approval scripts for agents (Elixir library).
Non-Turing-complete steppable script format driven call-by-call by a human,
with scoped allow/block command permissions and an MCP executor.

```
genai-approval/
├── lib/
│   └── genai/
│       ├── approval.ex                  # Public API surface (context module)
│       └── approval/
│           ├── application.ex           # Supervision tree root
│           ├── lexer.ex                 # Hand-rolled script lexer
│           ├── parser.ex                # Recursive-descent parser → AST
│           ├── expr.ex                  # Expression AST + evaluation
│           ├── static_checks.ex         # Undeclared vars/endpoints, purity, secret, caps
│           ├── script.ex                # Script/step structs
│           ├── runner.ex                # Steppable run GenServer (breakpoints, budgets)
│           ├── result.ex                # Per-step outcomes / result contract
│           ├── error.ex                 # Machine-readable error codes
│           ├── permission.ex            # Rule model + resolution
│           ├── permission/
│           │   └── store/               # dets / ets store backends
│           ├── executor/                # local + MCP step executors
│           ├── mcp/
│           │   └── submit_approval_script.ex  # submit_approval_script MCP tool
│           ├── host.ex                  # Host behaviour (render/interact)
│           ├── submit_host.ex           # SubmitHost behaviour (MCP flow)
│           ├── render.ex                # Rendering model
│           └── live/
│               └── run_view.ex          # LiveView reference UI (optional dep)
├── config/
│   └── config.exs                       # Test-env only config (endpoint, logger)
├── test/
│   ├── genai/approval/                  # Parser, runner, permission, executor, LiveView tests
│   ├── support/                         # Test endpoint + fixtures (compiled in :test)
│   └── test_helper.exs
├── docs/
│   └── arch/                            # → [layout/../arch.md](arch/) overview, script-format,
│                                        #   runner, permissions, ui, mcp
├── doc/                                 # Generated ex_doc output (gitignored)
├── .formatter.exs                       # Elixir formatter config
├── .tool-versions                       # elixir 1.20.1-otp-29 / erlang 29.0.2 (asdf/mise)
├── mix.exs                              # App :genai_approval; optional deps: LiveView, noizu_mcp
├── mix.lock
├── README.md                            # Start here — doc map + milestone status
├── AGENT.md / AGENTS.md                 # Agent guidance (mirrored)
└── CLAUDE.md                            # Claude Code guidance
```

## Key Files Requiring Setup

| File | Action |
|------|--------|
| `.tool-versions` | Ensure matching Elixir/Erlang via asdf/mise |
| none | No secrets/env config — library has no `.envrc` |

## Notes

- `deps/`, `_build/`, `doc/`, `cover/` are gitignored build artifacts — not documented.
- `.claude/worktrees/` is a local (gitignored) worktree slot — empty, not part of the tree.
- Architecture detail lives in `docs/arch/*.md` (see README table); this file maps structure only.
