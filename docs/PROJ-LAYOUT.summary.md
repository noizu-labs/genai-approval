# Project Layout (summary)

Plain tree companion to [PROJ-LAYOUT.md](PROJ-LAYOUT.md).

```
genai-approval/
├── lib/genai/approval.ex            # Public API surface
├── lib/genai/approval/              # Engine: application, lexer, parser, expr,
│                                    #   static_checks, script, runner, result, error,
│                                    #   permission(+store/dets,store/ets), executor/(local,mcp),
│                                    #   mcp/submit_approval_script, host, submit_host,
│                                    #   render, live/run_view (LiveView reference UI)
├── config/config.exs                # Test-env config only
├── test/genai/approval/             # Parser, runner, permission, executor, LiveView tests
├── test/support/                    # Test endpoint + fixtures
├── docs/arch/                       # overview, script-format, runner, permissions, ui, mcp
├── .formatter.exs
├── .tool-versions                   # elixir 1.20.1-otp-29 / erlang 29.0.2
├── mix.exs                          # app :genai_approval; optional: live_view, noizu_mcp
├── README.md
├── AGENT.md / AGENTS.md / CLAUDE.md # Agent guidance
```

Gitignored (not part of the tree): `deps/`, `_build/`, `doc/`, `cover/`, `.claude/worktrees/`.
