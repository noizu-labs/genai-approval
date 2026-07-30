defmodule GenAI.Approval.RunnerTest do
  use ExUnit.Case, async: true

  alias GenAI.Approval.Executor.Local
  alias GenAI.Approval.Fixtures

  # -- helpers ---------------------------------------------------------------

  defp load!(source) do
    {:ok, script} = GenAI.Approval.load(source)
    script
  end

  # Handlers echo to the test process so ordering/args can be asserted.
  defp echo_handlers(test_pid, extra \\ %{}) do
    Map.merge(
      %{
        "ping" => fn args, ctx ->
          send(test_pid, {:called, ctx.step_id, args})
          {:ok, %{"pong" => true}}
        end,
        "fetch" => fn args, ctx ->
          send(test_pid, {:called, ctx.step_id, args})
          {:ok, %{"value" => Map.get(args, "n", 0)}}
        end
      },
      extra
    )
  end

  defp start_run!(script, handlers, opts \\ []) do
    opts =
      Keyword.merge(
        [
          executors: %{"local" => {Local, handlers}},
          subscriber: self(),
          permission: [store: Fixtures.allow_all_store(), subject: "tester", session_id: "sess"]
        ],
        opts
      )

    {:ok, run} = GenAI.Approval.start_run(script, opts)
    run
  end

  defp two_step_script do
    load!(
      Fixtures.local_script("""
      {{#step "first"}}
        {{call "local" "ping" tag="one"}}
      {{/step}}
      {{#step "second"}}
        {{call "local" "ping" tag="two"}}
      {{/step}}
      """)
    )
  end

  # -- AC4: state machine ----------------------------------------------------

  describe "AC4 — step/next/run_all semantics" do
    test ":step executes exactly one step then pauses" do
      run = start_run!(two_step_script(), echo_handlers(self()))

      assert :ok = GenAI.Approval.command(run, :step)
      assert_receive {:called, "s1", %{"tag" => "one"}}

      assert_receive {:genai_approval, _,
                      %{type: :step_completed, step: "s1", status: :completed}}

      assert_receive {:genai_approval, _, %{type: :paused}}

      refute_received {:called, "s2", _}
      assert %{status: :paused, pending: nil} = GenAI.Approval.info(run)
    end

    test ":run_all runs to completion" do
      run = start_run!(two_step_script(), echo_handlers(self()))

      assert :ok = GenAI.Approval.command(run, :run_all)
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)

      assert_received {:called, "s1", _}
      assert_received {:called, "s2", _}
      assert result.status == :completed
      assert Enum.map(result.steps, & &1.status) == [:completed, :completed]
    end

    test ":next pauses at a breakpoint, resuming runs through it" do
      script =
        load!(
          Fixtures.local_script("""
          {{#step "first"}}
            {{call "local" "ping" tag="one"}}
          {{/step}}
          {{#step "second" breakpoint=true}}
            {{call "local" "ping" tag="two"}}
          {{/step}}
          {{#step "third"}}
            {{call "local" "ping" tag="three"}}
          {{/step}}
          """)
        )

      run = start_run!(script, echo_handlers(self()))

      assert :ok = GenAI.Approval.command(run, :next)
      assert_receive {:called, "s1", _}
      assert_receive {:genai_approval, _, %{type: :paused, at: "s2"}}, 2_000
      refute_received {:called, "s2", _}
      assert %{status: :paused, pending: "s2"} = GenAI.Approval.info(run)

      # resume runs through the hit breakpoint to completion
      assert :ok = GenAI.Approval.command(run, :next)
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)
      assert_received {:called, "s2", _}
      assert_received {:called, "s3", _}
      assert result.status == :completed
    end

    test "commands invalid for the current state are rejected" do
      run = start_run!(two_step_script(), echo_handlers(self()))

      assert {:error, {:invalid_command, :approve, :paused}} =
               GenAI.Approval.command(run, :approve)

      assert :ok = GenAI.Approval.command(run, :run_all)
      assert {:ok, _} = GenAI.Approval.await(run, 5_000)

      assert {:error, {:terminal, :completed}} = GenAI.Approval.command(run, :step)
    end
  end

  # -- AC5: branches ---------------------------------------------------------

  describe "AC5 — conditionals" do
    defp branch_script do
      Fixtures.local_script(
        """
        {{#if flag}}
          {{#step "yes"}} {{call "local" "ping" arm="then"}} {{/step}}
        {{else}}
          {{#step "no"}} {{call "local" "ping" arm="else"}} {{/step}}
        {{/if}}
        """,
        "{{#vars}} flag : boolean = false {{/vars}}"
      )
    end

    test "then-arm taken; else steps marked not_reached" do
      run =
        start_run!(load!(branch_script()), echo_handlers(self()), variables: %{"flag" => true})

      assert :ok = GenAI.Approval.command(run, :run_all)
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)

      assert_received {:called, "s1", %{"arm" => "then"}}
      assert [%{value: true, taken: "then"}] = result.branches

      assert %{"s1" => :completed, "s2" => :not_reached} =
               Map.new(result.steps, &{&1.id, &1.status})
    end

    test "else-arm taken when condition is falsy" do
      run = start_run!(load!(branch_script()), echo_handlers(self()))

      assert :ok = GenAI.Approval.command(run, :run_all)
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)

      assert_received {:called, "s2", %{"arm" => "else"}}
      assert [%{taken: "else"}] = result.branches

      assert %{"s1" => :not_reached, "s2" => :completed} =
               Map.new(result.steps, &{&1.id, &1.status})
    end

    test "unless negates" do
      source =
        Fixtures.local_script(
          """
          {{#unless flag}}
            {{#step "ran"}} {{call "local" "ping"}} {{/step}}
          {{/unless}}
          """,
          "{{#vars}} flag : boolean = false {{/vars}}"
        )

      run = start_run!(load!(source), echo_handlers(self()))
      assert :ok = GenAI.Approval.command(run, :run_all)
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)
      assert_received {:called, "s1", _}
      assert result.status == :completed
    end

    test "branch_decided event is emitted with the evaluated value" do
      run =
        start_run!(load!(branch_script()), echo_handlers(self()), variables: %{"flag" => true})

      assert :ok = GenAI.Approval.command(run, :run_all)
      assert {:ok, _} = GenAI.Approval.await(run, 5_000)
      assert_received {:genai_approval, _, %{type: :branch_decided, value: true, taken: "then"}}
    end
  end

  # -- AC6: edits ------------------------------------------------------------

  describe "AC6 — edits" do
    test "editing a pending step argument changes what executes and is recorded" do
      run = start_run!(two_step_script(), echo_handlers(self()))

      assert :ok = GenAI.Approval.command(run, {:edit, {:arg, "s1", "tag"}, "edited!"})
      assert :ok = GenAI.Approval.command(run, :run_all)
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)

      assert_received {:called, "s1", %{"tag" => "edited!"}}
      assert_received {:called, "s2", %{"tag" => "two"}}

      s1 = Enum.find(result.steps, &(&1.id == "s1"))
      assert s1.edited
      assert [call] = s1.calls
      assert call.args_submitted == %{"tag" => "one"}
      assert call.args_executed == %{"tag" => "edited!"}

      assert [%{path: ["step", "s1", "arg", "tag"], before: nil, after: "edited!"}] =
               Enum.map(result.edits, &Map.take(&1, [:path, :before, :after]))
    end

    test "editing a variable updates the environment" do
      source =
        Fixtures.local_script(
          """
          {{#step "use"}} {{call "local" "fetch" n=n}} {{/step}}
          """,
          "{{#vars}} n : number = 1 {{/vars}}"
        )

      run = start_run!(load!(source), echo_handlers(self()))
      assert :ok = GenAI.Approval.command(run, {:edit, {:var, "n"}, 42})
      assert :ok = GenAI.Approval.command(run, :run_all)
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)

      assert_received {:called, "s1", %{"n" => 42}}

      assert [%{path: ["var", "n"], before: 1, after: 42}] =
               Enum.map(result.edits, &Map.take(&1, [:path, :before, :after]))
    end

    test "editing an already-executed step is rejected" do
      run = start_run!(two_step_script(), echo_handlers(self()))
      assert :ok = GenAI.Approval.command(run, :step)
      assert_receive {:genai_approval, _, %{type: :step_completed, step: "s1"}}

      assert {:error, :step_already_executed} =
               GenAI.Approval.command(run, {:edit, {:arg, "s1", "tag"}, "x"})
    end
  end

  # -- AC7: halt -------------------------------------------------------------

  describe "AC7 — halt" do
    test "halt while paused, with a reason" do
      run = start_run!(two_step_script(), echo_handlers(self()))

      assert :ok = GenAI.Approval.command(run, {:halt, "not today"})
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)

      assert result.status == :halted
      assert result.halt.reason == "not today"
      assert result.halt.actor == :operator
      assert Enum.all?(result.steps, &(&1.status == :not_reached))
    end

    test "halt mid-execution kills the in-flight step" do
      test_pid = self()

      handlers =
        echo_handlers(self(), %{
          "slow" => fn _args, ctx ->
            send(test_pid, {:started_slow, ctx.step_id})
            Process.sleep(60_000)
            {:ok, %{}}
          end
        })

      source =
        Fixtures.local_script("""
        {{#step "slow one"}} {{call "local" "slow"}} {{/step}}
        """)

      run = start_run!(load!(source), handlers)
      assert :ok = GenAI.Approval.command(run, :step)
      assert_receive {:started_slow, "s1"}, 2_000

      assert :ok = GenAI.Approval.command(run, {:halt, "took too long"})
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)
      assert result.status == :halted
      assert result.halt.at_step == "s1"
    end

    test "notes are collected and returned" do
      run = start_run!(two_step_script(), echo_handlers(self()))
      assert :ok = GenAI.Approval.command(run, {:annotate, "s1", "looks fine"})
      assert :ok = GenAI.Approval.command(run, {:annotate, "run", "overall note"})
      assert :ok = GenAI.Approval.command(run, {:halt, nil})
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)

      assert [%{target: "s1", text: "looks fine"}, %{target: "run", text: "overall note"}] =
               Enum.map(result.notes, &Map.take(&1, [:target, :text]))
    end
  end

  # -- AC8: budgets ----------------------------------------------------------

  describe "AC8 — budgets" do
    test "per-step timeout fails the step and pauses" do
      handlers = %{"slow" => fn _a, _c -> Process.sleep(60_000) end}

      source =
        Fixtures.local_script("""
        {{#step "slow"}} {{call "local" "slow"}} {{/step}}
        """)

      run = start_run!(load!(source), handlers, budgets: [step_timeout: 60])
      assert :ok = GenAI.Approval.command(run, :step)

      assert_receive {:genai_approval, _,
                      %{type: :step_completed, step: "s1", status: :failed} = ev},
                     2_000

      assert ev.error =~ "timeout"
      assert %{status: :paused, pending: "s1", pending_failed: true} = GenAI.Approval.info(run)
    end

    test "run wall-clock budget halts the run" do
      run = start_run!(two_step_script(), echo_handlers(self()), budgets: [run_timeout: 80])
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)
      assert result.status == :halted
      assert result.halt.reason == "budget_exceeded"
    end

    test "idle timeout halts an unattended run (R7.6)" do
      run = start_run!(two_step_script(), echo_handlers(self()), budgets: [idle_timeout: 80])
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)
      assert result.status == :halted
      assert result.halt.reason == "operator_timeout"
    end
  end

  # -- AC9: failure handling -------------------------------------------------

  describe "AC9 — step failure" do
    test "failure pauses; retry once succeeds" do
      counter = :counters.new(1, [])

      handlers = %{
        "flaky" => fn _a, _c ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1 do
            {:error, :boom}
          else
            {:ok, %{"attempt" => 2}}
          end
        end
      }

      source =
        Fixtures.local_script("""
        {{#step "flaky"}} {{call "local" "flaky"}} {{/step}}
        """)

      run = start_run!(load!(source), handlers)
      assert :ok = GenAI.Approval.command(run, :step)
      assert_receive {:genai_approval, _, %{type: :step_completed, step: "s1", status: :failed}}

      assert :ok = GenAI.Approval.command(run, :retry)

      assert_receive {:genai_approval, _,
                      %{type: :step_completed, step: "s1", status: :completed}}

      # a second retry of the same step is refused
      assert {:error, _} = GenAI.Approval.command(run, :retry)
      assert :ok = GenAI.Approval.command(run, :run_all)
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)
      assert result.status == :completed
    end

    test "optional failed step can be skipped" do
      handlers = echo_handlers(self(), %{"broken" => fn _a, _c -> {:error, :nope} end})

      source =
        Fixtures.local_script("""
        {{#step "broken" optional=true}} {{call "local" "broken"}} {{/step}}
        {{#step "after"}} {{call "local" "ping"}} {{/step}}
        """)

      run = start_run!(load!(source), handlers)
      assert :ok = GenAI.Approval.command(run, :step)
      assert_receive {:genai_approval, _, %{type: :step_completed, step: "s1", status: :failed}}

      assert :ok = GenAI.Approval.command(run, :skip)
      assert :ok = GenAI.Approval.command(run, :run_all)
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)

      assert %{"s1" => :skipped, "s2" => :completed} = Map.new(result.steps, &{&1.id, &1.status})
    end

    test "skip is refused for non-optional steps" do
      handlers = %{"broken" => fn _a, _c -> {:error, :nope} end}

      source =
        Fixtures.local_script("""
        {{#step "broken"}} {{call "local" "broken"}} {{/step}}
        """)

      run = start_run!(load!(source), handlers)
      assert :ok = GenAI.Approval.command(run, :step)
      assert_receive {:genai_approval, _, %{type: :step_completed, status: :failed}}
      assert {:error, :not_optional} = GenAI.Approval.command(run, :skip)
    end

    test "failure during run_all halts with step_failed" do
      handlers = echo_handlers(self(), %{"broken" => fn _a, _c -> {:error, :nope} end})

      source =
        Fixtures.local_script("""
        {{#step "ok"}} {{call "local" "ping"}} {{/step}}
        {{#step "broken"}} {{call "local" "broken"}} {{/step}}
        {{#step "never"}} {{call "local" "ping"}} {{/step}}
        """)

      run = start_run!(load!(source), handlers)
      assert :ok = GenAI.Approval.command(run, :run_all)
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)

      assert result.status == :halted
      assert result.halt.reason == "step_failed"

      assert %{"s1" => :completed, "s2" => :failed, "s3" => :not_reached} =
               Map.new(result.steps, &{&1.id, &1.status})
    end

    @tag capture_log: true
    test "a crashing handler is captured as step failure" do
      handlers = %{"crash" => fn _a, _c -> raise "kaboom" end}

      source =
        Fixtures.local_script("""
        {{#step "crash"}} {{call "local" "crash"}} {{/step}}
        """)

      run = start_run!(load!(source), handlers)
      assert :ok = GenAI.Approval.command(run, :step)

      assert_receive {:genai_approval, _, %{type: :step_completed, step: "s1", status: :failed}},
                     2_000
    end
  end

  # -- AC15: local executor + env flow --------------------------------------

  describe "AC15 — local executor, env, outputs" do
    test "assign binds results; outputs return declared values" do
      handlers = %{
        "fetch" => fn args, _c -> {:ok, %{"value" => args["n"] * 2}} end
      }

      source =
        Fixtures.local_script(
          """
          {{#step "double"}}
            {{assign result = call("local", "fetch", n=n)}}
          {{/step}}
          """,
          """
          {{#vars}}
            n : number = 21
            result : object?
          {{/vars}}
          {{!-- outputs follow the body --}}
          """
        ) <>
          """
          {{#outputs}}
            answer = result.value
            echo_n = n
          {{/outputs}}
          """

      run = start_run!(load!(source), handlers)
      assert :ok = GenAI.Approval.command(run, :run_all)
      assert {:ok, result} = GenAI.Approval.await(run, 5_000)

      assert result.outputs == %{"answer" => 42, "echo_n" => 21}
      assert result.outputs_unavailable == []
    end

    test "unknown command fails the step" do
      source =
        Fixtures.local_script("""
        {{#step "s"}} {{call "local" "ghost"}} {{/step}}
        """)

      run = start_run!(load!(source), %{})
      assert :ok = GenAI.Approval.command(run, :step)

      assert_receive {:genai_approval, _, %{type: :step_completed, status: :failed} = ev}
      assert ev.error =~ "unknown_command"
    end

    test "missing executor for a declared endpoint fails at start" do
      assert {:error, _} = GenAI.Approval.start_run(two_step_script(), executors: %{})
    end
  end
end
