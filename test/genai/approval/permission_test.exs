defmodule GenAI.Approval.PermissionTest do
  use ExUnit.Case, async: true

  alias GenAI.Approval.Executor.Local
  alias GenAI.Approval.{Fixtures, Permission}
  alias GenAI.Approval.Permission.Store.ETS

  defp rule(pattern, effect, opts \\ []) do
    Permission.new(
      Keyword.merge([pattern: pattern, effect: effect, scope: :always, granted_by: "t"], opts)
    )
  end

  # -- AC10: resolution matrix ----------------------------------------------

  describe "AC10 — resolution matrix (§8.2)" do
    @now ~U[2026-07-31 12:00:00Z]

    # {test label, rules as {pattern, effect, scope}, endpoint, command, expected}
    matrix = [
      {"no rules -> ask", [], "github", "issues.create", :ask},
      {"wildcard allow", [{"*:*", :allow, :always}], "github", "issues.create", :allow},
      {"wildcard block", [{"*:*", :block, :always}], "github", "issues.create", :block},
      {"exact allow", [{"github:issues.create", :allow, :always}], "github", "issues.create",
       :allow},
      {"exact no match (cmd) -> ask", [{"github:issues.create", :allow, :always}], "github",
       "issues.delete", :ask},
      {"exact no match (ep) -> ask", [{"github:issues.create", :allow, :always}], "gitlab",
       "issues.create", :ask},
      {"glob matches child", [{"github:issues.*", :allow, :always}], "github", "issues.create",
       :allow},
      {"glob matches deep child", [{"github:issues.*", :allow, :always}], "github",
       "issues.comment.reply", :allow},
      {"glob matches its own prefix", [{"github:issues.*", :allow, :always}], "github", "issues",
       :allow},
      {"glob does not match sibling", [{"github:issues.*", :allow, :always}], "github",
       "pulls.create", :ask},
      {"exact beats glob (block wins by specificity)",
       [{"github:issues.*", :allow, :always}, {"github:issues.create", :block, :always}],
       "github", "issues.create", :block},
      {"exact beats glob (allow wins by specificity)",
       [{"github:issues.*", :block, :always}, {"github:issues.create", :allow, :always}],
       "github", "issues.create", :allow},
      {"glob beats endpoint wildcard-cmd",
       [{"github:*", :block, :always}, {"github:issues.*", :allow, :always}], "github",
       "issues.create", :allow},
      {"longer glob beats shorter glob",
       [{"github:issues.*", :block, :always}, {"github:issues.comment.*", :allow, :always}],
       "github", "issues.comment.reply", :allow},
      {"exact endpoint beats wildcard endpoint at equal cmd",
       [{"*:*", :block, :always}, {"github:*", :allow, :always}], "github", "anything", :allow},
      {"command specificity dominates endpoint specificity",
       [{"github:*", :allow, :always}, {"*:issues.create", :block, :always}], "github",
       "issues.create", :block},
      {"block beats allow at equal specificity",
       [{"github:issues.*", :allow, :always}, {"github:issues.*", :block, :always}], "github",
       "issues.create", :block},
      {"unrelated block does not affect ask", [{"gitlab:*", :block, :always}], "github", "x",
       :ask},
      {"expired until-rule ignored -> ask",
       [{"github:*", :allow, {:until, ~U[2026-07-31 11:00:00Z]}}], "github", "x", :ask},
      {"live until-rule applies", [{"github:*", :allow, {:until, ~U[2026-07-31 13:00:00Z]}}],
       "github", "x", :allow},
      {"expired block falls back to wider allow",
       [
         {"github:issues.create", :block, {:until, ~U[2026-07-31 11:00:00Z]}},
         {"github:*", :allow, :always}
       ], "github", "issues.create", :allow},
      {"session-scoped allow", [{"github:*", :allow, :session}], "github", "x", :allow}
    ]

    for {{label, rules_spec, endpoint, command, expected}, idx} <- Enum.with_index(matrix) do
      test "#{idx}: #{label}" do
        rules =
          Enum.map(unquote(Macro.escape(rules_spec)), fn {pattern, effect, scope} ->
            rule(pattern, effect, scope: scope)
          end)

        outcome =
          case Permission.decide(rules, unquote(endpoint), unquote(command), @now) do
            :ask -> :ask
            {effect, %Permission.Rule{}} -> effect
          end

        assert outcome == unquote(expected)
      end
    end

    test "narrower scope wins at equal specificity and effect" do
      session = rule("github:*", :allow, scope: :session)
      always = rule("github:*", :allow, scope: :always)

      assert {:allow, winner} = Permission.decide([always, session], "github", "x", @now)
      assert winner.scope == :session
    end
  end

  # -- AC11: time-boxed grants ----------------------------------------------

  describe "AC11 — time-boxed rules" do
    test "'for the next hour' stores an absolute expiry and lapses" do
      now = DateTime.utc_now()
      r = rule("a:b", :allow, scope: {:until, DateTime.add(now, 3600, :second)})

      assert {:allow, _} = Permission.decide([r], "a", "b", now)
      assert {:allow, _} = Permission.decide([r], "a", "b", DateTime.add(now, 3599, :second))
      assert :ask == Permission.decide([r], "a", "b", DateTime.add(now, 3601, :second))
    end
  end

  # -- AC13: store behaviour --------------------------------------------------

  describe "AC13 — ETS store" do
    test "put / rules / revoke round trip" do
      table = ETS.new()
      r = rule("github:*", :allow)

      assert :ok = ETS.put(table, r)
      assert {:ok, [got]} = ETS.rules(table, nil, nil)
      assert got.id == r.id

      assert :ok = ETS.revoke(table, r.id)
      assert {:ok, []} = ETS.rules(table, nil, nil)
    end

    test ":call scope is never stored" do
      table = ETS.new()
      assert {:error, :call_scope_not_stored} = ETS.put(table, rule("a:b", :allow, scope: :call))
    end

    test "subject scoping: other subjects' rules are not returned" do
      table = ETS.new()
      :ok = ETS.put(table, rule("a:b", :allow, subject: "alice"))
      :ok = ETS.put(table, rule("c:d", :allow))

      assert {:ok, rules} = ETS.rules(table, "bob", nil)
      assert Enum.map(rules, & &1.pattern) == ["c:d"]

      assert {:ok, rules} = ETS.rules(table, "alice", nil)
      assert Enum.map(rules, & &1.pattern) |> Enum.sort() == ["a:b", "c:d"]
    end

    test "session rules only match their session" do
      table = ETS.new()
      :ok = ETS.put(table, rule("a:b", :allow, scope: :session, session_id: "s1"))

      assert {:ok, [_]} = ETS.rules(table, nil, "s1")
      assert {:ok, []} = ETS.rules(table, nil, "s2")
    end

    test "expired rules are lazily pruned on read" do
      table = ETS.new()
      past = DateTime.add(DateTime.utc_now(), -10, :second)
      :ok = ETS.put(table, rule("a:b", :allow, scope: {:until, past}))

      assert {:ok, []} = ETS.rules(table, nil, nil)
      assert {:ok, []} = ETS.list(table)
    end
  end

  # -- AC12 + grants: runner integration -------------------------------------

  describe "runner integration" do
    defp start_gated_run!(store) do
      test_pid = self()

      handlers = %{
        "ping" => fn args, ctx ->
          send(test_pid, {:called, ctx.step_id, args})
          {:ok, %{}}
        end
      }

      source =
        Fixtures.local_script("""
        {{#step "one"}} {{call "local" "ping"}} {{/step}}
        {{#step "two"}} {{call "local" "ping"}} {{/step}}
        """)

      {:ok, script} = GenAI.Approval.load(source)

      {:ok, run} =
        GenAI.Approval.start_run(script,
          executors: %{"local" => {Local, handlers}},
          subscriber: self(),
          permission: [store: store, subject: "tester", session_id: "sess"]
        )

      run
    end

    test "no matching rule -> permission_required; approve executes once" do
      run = start_gated_run!(Fixtures.empty_store())

      assert :ok = GenAI.Approval.command(run, :step)
      assert_receive {:genai_approval, _, %{type: :permission_required, step: "s1"}}
      refute_received {:called, "s1", _}

      assert :ok = GenAI.Approval.command(run, :approve)
      assert_receive {:called, "s1", _}

      assert_receive {:genai_approval, _,
                      %{type: :step_completed, step: "s1", status: :completed}}

      # next step asks again — approve was :call-scoped
      assert :ok = GenAI.Approval.command(run, :step)
      assert_receive {:genai_approval, _, %{type: :permission_required, step: "s2"}}
    end

    test "decline records the step as declined and pauses" do
      run = start_gated_run!(Fixtures.empty_store())

      assert :ok = GenAI.Approval.command(run, :step)
      assert_receive {:genai_approval, _, %{type: :permission_required}}
      assert :ok = GenAI.Approval.command(run, :decline)

      assert_receive {:genai_approval, _, %{type: :step_completed, step: "s1", status: :declined}}
      refute_received {:called, "s1", _}
      assert %{status: :paused} = GenAI.Approval.info(run)
    end

    test "session grant persists for later steps in the run" do
      {_mod, table} = store = Fixtures.empty_store()
      run = start_gated_run!(store)

      assert :ok = GenAI.Approval.command(run, :run_all)
      assert_receive {:genai_approval, _, %{type: :permission_required, step: "s1"}}

      assert :ok = GenAI.Approval.command(run, {:grant, :allow, :session})
      # run_all continues: s1 executes, s2 is auto-allowed by the stored rule
      assert_receive {:called, "s1", _}
      assert_receive {:called, "s2", _}
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)
      assert result.status == :completed

      assert [%{pattern: "local:ping", effect: :allow, scope: :session}] =
               Enum.map(result.grants, &Map.take(&1, [:pattern, :effect, :scope]))

      assert {:ok, [stored]} = ETS.rules(table, "tester", "sess")
      assert stored.pattern == "local:ping"
    end

    test "AC12 — block rule halts the run at the matching step" do
      {_mod, table} = store = Fixtures.empty_store()

      :ok =
        ETS.put(
          table,
          Permission.new(pattern: "local:ping", effect: :block, scope: :always, granted_by: "t")
        )

      run = start_gated_run!(store)
      assert :ok = GenAI.Approval.command(run, :run_all)
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)

      assert result.status == :halted
      assert result.halt.reason == "blocked_by_policy"
      assert result.halt.at_step == "s1"
      refute_received {:called, _, _}
    end

    test "block grant from the prompt halts immediately (R8.2)" do
      run = start_gated_run!(Fixtures.empty_store())

      assert :ok = GenAI.Approval.command(run, :step)
      assert_receive {:genai_approval, _, %{type: :permission_required}}

      assert :ok = GenAI.Approval.command(run, {:grant, :block, :session})
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)
      assert result.status == :halted
      assert result.halt.reason == "blocked_by_policy"
    end

    test "confirm steps always ask, even with an allow-all rule (R5.7)" do
      test_pid = self()

      handlers = %{
        "ping" => fn _a, _c ->
          send(test_pid, :pinged)
          {:ok, %{}}
        end
      }

      source =
        Fixtures.local_script("""
        {{#step "danger" confirm="really do it"}} {{call "local" "ping"}} {{/step}}
        """)

      {:ok, script} = GenAI.Approval.load(source)

      {:ok, run} =
        GenAI.Approval.start_run(script,
          executors: %{"local" => {Local, handlers}},
          subscriber: self(),
          permission: [store: Fixtures.allow_all_store(), subject: "t", session_id: "s"]
        )

      assert :ok = GenAI.Approval.command(run, :run_all)
      assert_receive {:genai_approval, _, %{type: :permission_required, confirm: "really do it"}}
      refute_received :pinged

      assert :ok = GenAI.Approval.command(run, :approve)
      assert_receive :pinged
      assert {:ok, %{status: :completed}} = GenAI.Approval.await(run, 5_000)
    end
  end
end
