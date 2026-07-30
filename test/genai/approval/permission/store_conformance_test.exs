defmodule GenAI.Approval.Permission.StoreConformanceTest do
  @moduledoc """
  AC13 — one conformance suite, run against every store implementation
  (ETS in-memory, DETS durable). Add new stores to `@stores`.
  """
  use ExUnit.Case, async: true

  alias GenAI.Approval.Permission
  alias GenAI.Approval.Permission.Store.DETS, as: DetsStore
  alias GenAI.Approval.Permission.Store.ETS, as: EtsStore

  defp rule(pattern, effect, opts \\ []) do
    Permission.new(
      Keyword.merge([pattern: pattern, effect: effect, scope: :always, granted_by: "t"], opts)
    )
  end

  defp new_store(:ets, _ctx), do: {EtsStore, EtsStore.new()}

  defp new_store(:dets, ctx) do
    name = :"dets_conformance_#{System.unique_integer([:positive])}"
    path = Path.join(ctx.tmp_dir, "#{name}.dets")
    start_supervised!({DetsStore, name: name, path: path})
    {DetsStore, name}
  end

  for kind <- [:ets, :dets] do
    describe "#{kind} store conformance" do
      @describetag :tmp_dir

      test "put / rules / revoke round trip", ctx do
        {mod, ref} = new_store(unquote(kind), ctx)
        r = rule("github:*", :allow)

        assert :ok = mod.put(ref, r)
        assert {:ok, [got]} = mod.rules(ref, nil, nil)
        assert got.id == r.id

        assert :ok = mod.revoke(ref, r.id)
        assert {:ok, []} = mod.rules(ref, nil, nil)
      end

      test ":call scope is never stored", ctx do
        {mod, ref} = new_store(unquote(kind), ctx)

        assert {:error, :call_scope_not_stored} =
                 mod.put(ref, rule("a:b", :allow, scope: :call))
      end

      test "subject scoping", ctx do
        {mod, ref} = new_store(unquote(kind), ctx)
        :ok = mod.put(ref, rule("a:b", :allow, subject: "alice"))
        :ok = mod.put(ref, rule("c:d", :allow))

        assert {:ok, rules} = mod.rules(ref, "bob", nil)
        assert Enum.map(rules, & &1.pattern) == ["c:d"]

        assert {:ok, rules} = mod.rules(ref, "alice", nil)
        assert Enum.map(rules, & &1.pattern) |> Enum.sort() == ["a:b", "c:d"]
      end

      test "session rules only match their session", ctx do
        {mod, ref} = new_store(unquote(kind), ctx)
        :ok = mod.put(ref, rule("a:b", :allow, scope: :session, session_id: "s1"))

        assert {:ok, [_]} = mod.rules(ref, nil, "s1")
        assert {:ok, []} = mod.rules(ref, nil, "s2")
      end

      test "expired rules are lazily pruned on read", ctx do
        {mod, ref} = new_store(unquote(kind), ctx)
        past = DateTime.add(DateTime.utc_now(), -10, :second)
        :ok = mod.put(ref, rule("a:b", :allow, scope: {:until, past}))

        assert {:ok, []} = mod.rules(ref, nil, nil)
        assert {:ok, []} = mod.list(ref)
      end
    end
  end

  describe "DETS durability (M3)" do
    @describetag :tmp_dir

    test "rules survive a store restart", ctx do
      path = Path.join(ctx.tmp_dir, "durable.dets")
      name = :"dets_durable_#{System.unique_integer([:positive])}"

      pid = start_supervised!({DetsStore, name: name, path: path}, id: :first)
      r = rule("github:issues.*", :allow, subject: "keith")
      :ok = DetsStore.put(name, r)
      :ok = stop_supervised(:first)
      refute Process.alive?(pid)

      name2 = :"dets_durable_#{System.unique_integer([:positive])}"
      start_supervised!({DetsStore, name: name2, path: path}, id: :second)

      assert {:ok, [got]} = DetsStore.rules(name2, "keith", nil)
      assert got.id == r.id
      assert got.pattern == "github:issues.*"
    end

    test "a durable block rule gates a fresh run after restart", ctx do
      path = Path.join(ctx.tmp_dir, "block.dets")
      name = :"dets_block_#{System.unique_integer([:positive])}"

      start_supervised!({DetsStore, name: name, path: path}, id: :first)
      :ok = DetsStore.put(name, rule("local:ping", :block))
      :ok = stop_supervised(:first)

      name2 = :"dets_block_#{System.unique_integer([:positive])}"
      start_supervised!({DetsStore, name: name2, path: path}, id: :second)

      source =
        GenAI.Approval.Fixtures.local_script("""
        {{#step "one"}} {{call "local" "ping"}} {{/step}}
        """)

      {:ok, script} = GenAI.Approval.load(source)

      {:ok, run} =
        GenAI.Approval.start_run(script,
          executors: %{
            "local" => {GenAI.Approval.Executor.Local, %{"ping" => fn _, _ -> {:ok, %{}} end}}
          },
          permission: [store: {DetsStore, name2}, subject: "keith", session_id: "s"]
        )

      assert :ok = GenAI.Approval.command(run, :run_all)
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)
      assert result.status == :halted
      assert result.halt.reason == "blocked_by_policy"
    end
  end
end
