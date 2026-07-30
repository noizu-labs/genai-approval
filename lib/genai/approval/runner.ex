defmodule GenAI.Approval.Runner do
  @moduledoc """
  One interactive approval run (PRD §6): a GenServer holding the run state
  machine. Steps execute in supervised tasks so control commands (halt above
  all) stay responsive while a call is in flight.

  States: `:paused` → `:awaiting_permission` → `:executing` → … →
  `:completed | :halted | :failed`.

  Commands (see `command/2`): `:step`, `:next`, `:run_all`, `{:halt, reason}`,
  `:approve`, `:decline`, `{:grant, effect, scope}`, `{:grant, effect, scope,
  pattern}`, `:retry`, `:skip`, `{:edit, target, value}`,
  `{:set_breakpoint, id}`, `{:clear_breakpoint, id}`, `{:annotate, target, text}`.

  Events are sent to the subscriber as `{:genai_approval, run_id, event}` maps
  with a monotonic `:seq`.
  """

  use GenServer

  alias GenAI.Approval.{Expr, Permission, Script}
  alias GenAI.Approval.Script.{Assign, Call, If, Step}

  @default_budgets [step_timeout: 60_000, run_timeout: 1_800_000, idle_timeout: 900_000]
  @event_ring 500

  # -- client ----------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def command(run, cmd), do: GenServer.call(run, {:command, cmd})

  @doc "Block until the run reaches a terminal state; returns the §9 result."
  def await(run, timeout \\ :infinity), do: GenServer.call(run, :await, timeout)

  def info(run), do: GenServer.call(run, :info)

  def events(run), do: GenServer.call(run, :events)

  # -- init ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    script = Keyword.fetch!(opts, :script)
    run_id = Keyword.get_lazy(opts, :run_id, &generate_run_id/0)

    if Process.whereis(GenAI.Approval.Registry) do
      Registry.register(GenAI.Approval.Registry, run_id, nil)
    end

    with {:ok, executors} <- prepare_executors(script, Keyword.get(opts, :executors, %{})) do
      budgets =
        @default_budgets
        |> Keyword.merge(Keyword.get(opts, :budgets, []))
        |> Map.new()

      env =
        script.vars
        |> Enum.filter(& &1.has_default)
        |> Map.new(&{&1.name, &1.default})
        |> Map.merge(Keyword.get(opts, :variables, %{}))

      breakpoints =
        script.steps
        |> Enum.filter(&(&1.attrs["breakpoint"] == true))
        |> MapSet.new(& &1.id)

      permission =
        opts
        |> Keyword.get(:permission, [])
        |> then(
          &%{
            store: Keyword.get(&1, :store),
            subject: Keyword.get(&1, :subject),
            session_id: Keyword.get(&1, :session_id)
          }
        )

      state = %{
        run_id: run_id,
        script: script,
        env: env,
        frontier: script.body,
        status: :paused,
        mode: nil,
        pending: nil,
        pending_failed: false,
        awaiting: nil,
        executors: executors,
        results: %{},
        not_reached: MapSet.new(),
        branch_log: [],
        edits: [],
        notes: [],
        grants: [],
        breakpoints: breakpoints,
        bp_hits: MapSet.new(),
        overrides: %{},
        subscriber: Keyword.get(opts, :subscriber),
        seq: 0,
        events: [],
        waiters: [],
        budgets: budgets,
        timers: %{},
        task: nil,
        via: nil,
        retried: MapSet.new(),
        progressed: false,
        started_at: System.monotonic_time(:millisecond),
        result: nil,
        halt_info: nil,
        permission: permission
      }

      state =
        state
        |> arm_timer(:run, budgets.run_timeout)
        |> arm_timer(:idle, budgets.idle_timeout)
        |> emit(:run_loaded, %{
          steps: Enum.map(script.steps, &%{id: &1.id, title: &1.title, line: &1.line}),
          endpoints: Map.keys(script.endpoints)
        })
        |> emit(:paused, %{at: nil})

      telemetry(:run, :start, %{}, %{run_id: run_id})
      {:ok, state}
    else
      {:error, reason} -> {:stop, {:executor_error, reason}}
    end
  end

  defp prepare_executors(script, config) do
    Enum.reduce_while(script.endpoints, {:ok, %{}}, fn {alias_name, decl}, {:ok, acc} ->
      case Map.fetch(config, alias_name) do
        {:ok, {mod, cfg}} ->
          case mod.prepare(decl, cfg) do
            {:ok, ex_state} -> {:cont, {:ok, Map.put(acc, alias_name, {mod, ex_state})}}
            {:error, reason} -> {:halt, {:error, {alias_name, reason}}}
          end

        :error ->
          {:halt, {:error, {alias_name, :no_executor_configured}}}
      end
    end)
  end

  defp generate_run_id do
    "run_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  # -- calls -----------------------------------------------------------------

  @impl GenServer
  def handle_call(:info, _from, state) do
    {:reply,
     %{
       run_id: state.run_id,
       status: state.status,
       mode: state.mode,
       pending: state.pending && state.pending.id,
       pending_failed: state.pending_failed,
       seq: state.seq
     }, state}
  end

  def handle_call(:events, _from, state) do
    {:reply, Enum.reverse(state.events), state}
  end

  def handle_call(:await, from, state) do
    if terminal?(state.status) do
      {:reply, {:ok, state.result}, state}
    else
      {:noreply, %{state | waiters: [from | state.waiters]}}
    end
  end

  def handle_call({:command, cmd}, _from, state) do
    if terminal?(state.status) do
      {:reply, {:error, {:terminal, state.status}}, state}
    else
      state = reset_idle(state)
      dispatch_command(cmd, state)
    end
  end

  # -- command dispatch ------------------------------------------------------

  defp dispatch_command({:halt, reason}, state) do
    {:reply, :ok, do_halt(state, reason || "halted by operator", :operator)}
  end

  defp dispatch_command({:annotate, target, text}, state) do
    note = %{target: target, text: text, at: DateTime.utc_now()}
    state = emit(%{state | notes: state.notes ++ [note]}, :annotated, note)
    {:reply, :ok, state}
  end

  defp dispatch_command({:set_breakpoint, id}, state) do
    state = %{state | breakpoints: MapSet.put(state.breakpoints, id)}
    {:reply, :ok, emit(state, :breakpoint_set, %{step: id})}
  end

  defp dispatch_command({:clear_breakpoint, id}, state) do
    state = %{state | breakpoints: MapSet.delete(state.breakpoints, id)}
    {:reply, :ok, emit(state, :breakpoint_cleared, %{step: id})}
  end

  defp dispatch_command({:edit, target, value}, state)
       when state.status in [:paused, :awaiting_permission] do
    apply_edit(target, value, state)
  end

  defp dispatch_command(cmd, state) when cmd in [:step, :next, :run_all] do
    cond do
      state.status != :paused ->
        {:reply, {:error, {:invalid_in_state, state.status}}, state}

      state.pending_failed ->
        {:reply, {:error, :step_failed_retry_or_skip}, state}

      true ->
        mode = if cmd == :step, do: :step, else: cmd
        state = %{state | mode: mode, progressed: false}
        {:reply, :ok, proceed(state)}
    end
  end

  defp dispatch_command(:approve, %{status: :awaiting_permission} = state) do
    {:reply, :ok, execute_step(%{state | awaiting: nil}, :operator)}
  end

  defp dispatch_command(:decline, %{status: :awaiting_permission} = state) do
    step = state.pending

    state =
      %{state | via: nil}
      |> record_result(step, :declined, [], nil)
      |> Map.merge(%{pending: nil, awaiting: nil})
      |> do_pause()

    {:reply, :ok, state}
  end

  defp dispatch_command({:grant, effect, scope}, %{status: :awaiting_permission} = state) do
    pattern = default_pattern(state)
    dispatch_command({:grant, effect, scope, pattern}, state)
  end

  defp dispatch_command({:grant, effect, scope, pattern}, %{status: :awaiting_permission} = state)
       when effect in [:allow, :block] do
    scope = normalize_scope(scope)

    rule =
      Permission.new(
        pattern: pattern,
        effect: effect,
        scope: scope,
        subject: state.permission.subject,
        session_id: if(scope == :session, do: state.permission.session_id),
        granted_by: state.permission.subject || "operator"
      )

    state =
      case {scope, state.permission.store} do
        {:call, _} ->
          state

        {_, {mod, ref}} ->
          :ok = mod.put(ref, rule)
          state

        {_, nil} ->
          state
      end

    grant = %{pattern: pattern, effect: effect, scope: scope, rule_id: rule.id}
    state = emit(%{state | grants: state.grants ++ [grant]}, :permission_granted, grant)
    telemetry(:permission, :grant, %{}, Map.put(grant, :run_id, state.run_id))

    case effect do
      :allow -> {:reply, :ok, execute_step(%{state | awaiting: nil}, {:rule, rule.id})}
      :block -> {:reply, :ok, blocked_halt(state, rule)}
    end
  end

  defp dispatch_command(:retry, %{status: :paused, pending_failed: true} = state) do
    if MapSet.member?(state.retried, state.pending.id) do
      {:reply, {:error, :already_retried}, state}
    else
      state = %{
        state
        | retried: MapSet.put(state.retried, state.pending.id),
          pending_failed: false
      }

      {:reply, :ok, execute_step(state, :operator_retry)}
    end
  end

  defp dispatch_command(:skip, %{status: :paused, pending_failed: true} = state) do
    step = state.pending

    if step.attrs["optional"] == true do
      state =
        %{state | via: nil}
        |> record_result(step, :skipped, [], nil)
        |> Map.merge(%{pending: nil, pending_failed: false})
        |> do_pause()

      {:reply, :ok, state}
    else
      {:reply, {:error, :not_optional}, state}
    end
  end

  defp dispatch_command(cmd, state) do
    {:reply, {:error, {:invalid_command, cmd, state.status}}, state}
  end

  defp normalize_scope({:for, seconds}) when is_integer(seconds) do
    {:until, DateTime.add(DateTime.utc_now(), seconds, :second)}
  end

  defp normalize_scope(scope), do: scope

  defp default_pattern(%{pending: %Step{calls: [{ep, cmd} | _]}}), do: "#{ep}:#{cmd}"
  defp default_pattern(_), do: "*:*"

  # -- edits -----------------------------------------------------------------

  defp apply_edit({:var, name}, value, state) do
    if Enum.any?(state.script.vars, &(&1.name == name)) do
      edit = %{
        path: ["var", name],
        before: Map.get(state.env, name),
        after: value,
        at: DateTime.utc_now()
      }

      state = %{state | env: Map.put(state.env, name, value), edits: state.edits ++ [edit]}
      {:reply, :ok, emit(state, :edited, edit)}
    else
      {:reply, {:error, :undeclared_var}, state}
    end
  end

  defp apply_edit({:arg, step_id, arg_name}, value, state) do
    executed? = Map.has_key?(state.results, step_id)

    if executed? do
      {:reply, {:error, :step_already_executed}, state}
    else
      step_overrides = Map.get(state.overrides, step_id, %{})

      edit = %{
        path: ["step", step_id, "arg", arg_name],
        before: Map.get(step_overrides, arg_name),
        after: value,
        at: DateTime.utc_now()
      }

      overrides = Map.put(state.overrides, step_id, Map.put(step_overrides, arg_name, value))
      state = %{state | overrides: overrides, edits: state.edits ++ [edit]}
      {:reply, :ok, emit(state, :edited, edit)}
    end
  end

  defp apply_edit(target, _value, state) do
    {:reply, {:error, {:invalid_edit_target, target}}, state}
  end

  # -- progression -----------------------------------------------------------

  # A pending step exists (fresh or paused-at): gate it. Otherwise pull the
  # next item off the frontier.
  defp proceed(%{pending: %Step{}} = state), do: gate_or_pause(state)

  defp proceed(state) do
    case pop_next(state) do
      {:done, state} -> complete(state)
      {:pause_branch, state} -> do_pause(state)
      {:step, step, state} -> gate_or_pause(%{state | pending: step})
      {:error, reason, state} -> do_fail(state, reason)
    end
  end

  defp pop_next(%{frontier: []} = state), do: {:done, state}

  defp pop_next(%{frontier: [%If{} = node | rest]} = state) do
    if state.mode == :next and state.progressed do
      {:pause_branch, state}
    else
      case Expr.eval(node.condition, state.env, :forbidden) do
        {:ok, value} ->
          truthy = Expr.truthy?(value)
          taken? = if node.negate, do: not truthy, else: truthy

          {taken_body, untaken_body} =
            if taken?,
              do: {node.then_body, node.else_body},
              else: {node.else_body, node.then_body}

          decision = %{
            line: node.line,
            negate: node.negate,
            value: value,
            taken: if(taken?, do: "then", else: "else")
          }

          state =
            %{
              state
              | frontier: taken_body ++ rest,
                branch_log: state.branch_log ++ [decision],
                not_reached:
                  MapSet.union(state.not_reached, MapSet.new(Script.step_ids(untaken_body)))
            }
            |> emit(:branch_decided, decision)

          pop_next(state)

        {:error, reason} ->
          {:error, {:condition_error, reason}, state}
      end
    end
  end

  defp pop_next(%{frontier: [%Step{} = step | rest]} = state) do
    {:step, step, %{state | frontier: rest}}
  end

  # Fast-forward modes stop at a breakpoint *before* the gate; once paused
  # there, the id lands in `bp_hits` so resuming (any mode) runs through it.
  defp gate_or_pause(%{pending: step} = state) do
    if state.mode in [:next, :run_all] and MapSet.member?(state.breakpoints, step.id) and
         not MapSet.member?(state.bp_hits, step.id) do
      do_pause(%{state | bp_hits: MapSet.put(state.bp_hits, step.id)})
    else
      gate(state)
    end
  end

  defp gate(%{pending: step} = state) do
    confirm = step.attrs["confirm"]

    cond do
      is_binary(confirm) ->
        ask(state, confirm)

      step.calls == [] ->
        execute_step(state, :no_side_effects)

      true ->
        case resolve_permission(state, step) do
          {:allow, rules} -> execute_step(state, {:rules, Enum.map(rules, & &1.id)})
          {:block, rule} -> blocked_halt(state, rule)
          :ask -> ask(state, nil)
        end
    end
  end

  defp ask(%{pending: step} = state, confirm) do
    payload = %{
      step: step.id,
      title: step.title,
      calls: Enum.map(step.calls, fn {e, c} -> %{endpoint: e, command: c} end),
      confirm: confirm
    }

    state = %{state | status: :awaiting_permission, awaiting: payload}
    emit(state, :permission_required, payload)
  end

  defp resolve_permission(state, step) do
    rules = fetch_rules(state)
    now = DateTime.utc_now()

    decisions =
      Enum.map(step.calls, fn {ep, cmd} ->
        decision = Permission.decide(rules, ep, cmd, now)

        telemetry(:permission, :decision, %{}, %{
          run_id: state.run_id,
          endpoint: ep,
          command: cmd,
          decision: elem_or_ask(decision)
        })

        decision
      end)

    cond do
      block =
          Enum.find_value(decisions, fn
            {:block, rule} -> rule
            _ -> nil
          end) ->
        {:block, block}

      Enum.any?(decisions, &(&1 == :ask)) ->
        :ask

      true ->
        {:allow, Enum.map(decisions, fn {:allow, rule} -> rule end)}
    end
  end

  defp elem_or_ask(:ask), do: :ask
  defp elem_or_ask({effect, _rule}), do: effect

  defp fetch_rules(%{permission: %{store: nil}}), do: []

  defp fetch_rules(%{permission: %{store: {mod, ref}} = perm}) do
    case mod.rules(ref, perm.subject, perm.session_id) do
      {:ok, rules} -> rules
      _ -> []
    end
  end

  defp blocked_halt(state, rule) do
    state =
      emit(state, :blocked, %{
        step: state.pending && state.pending.id,
        rule_id: rule.id,
        pattern: rule.pattern
      })

    do_halt(%{state | awaiting: nil}, "blocked_by_policy", :policy, %{
      rule_id: rule.id,
      pattern: rule.pattern
    })
  end

  # -- execution -------------------------------------------------------------

  defp execute_step(%{pending: %Step{} = step} = state, via) do
    run_ctx = %{run_id: state.run_id, step_id: step.id, env: state.env}
    env = state.env
    executors = state.executors
    overrides = Map.get(state.overrides, step.id, %{})

    task =
      Task.Supervisor.async_nolink(GenAI.Approval.TaskSupervisor, fn ->
        run_step(step, env, executors, overrides, run_ctx)
      end)

    state =
      %{
        state
        | status: :executing,
          task: %{
            ref: task.ref,
            pid: task.pid,
            step_id: step.id,
            started_at: System.monotonic_time(:millisecond)
          },
          via: via
      }
      |> arm_step_timer(task.ref)
      |> emit(:step_started, %{step: step.id, title: step.title, via: inspect(via)})

    telemetry(:step, :start, %{}, %{run_id: state.run_id, step_id: step.id})
    state
  end

  defp run_step(step, env, executors, overrides, ctx) do
    Process.put(:genai_approval_calls, [])

    outcome =
      Enum.reduce_while(step.statements, {:ok, env}, fn stmt, {:ok, acc_env} ->
        case exec_stmt(stmt, acc_env, executors, overrides, ctx) do
          {:ok, env2} -> {:cont, {:ok, env2}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    calls = Enum.reverse(Process.get(:genai_approval_calls, []))

    case outcome do
      {:ok, env2} -> {:ok, %{env: env2, calls: calls}}
      {:error, reason} -> {:error, reason, calls}
    end
  end

  defp exec_stmt(%Assign{var: var, expr: expr}, env, executors, overrides, ctx) do
    case Expr.eval(expr, env, call_fn(executors, overrides, ctx)) do
      {:ok, v} -> {:ok, Map.put(env, var, v)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp exec_stmt(%Call{endpoint: ep, command: cmd, args: args}, env, executors, overrides, ctx) do
    with {:ok, args_map} <- Expr.eval_args(args, env, call_fn(executors, overrides, ctx)),
         {:ok, _result} <- do_call(ep, cmd, args_map, executors, overrides, ctx) do
      {:ok, env}
    end
  end

  defp call_fn(executors, overrides, ctx) do
    fn ep, cmd, args -> do_call(ep, cmd, args, executors, overrides, ctx) end
  end

  defp do_call(ep, cmd, args_submitted, executors, overrides, ctx) do
    {mod, ex_state} = Map.fetch!(executors, ep)
    args_executed = Map.merge(args_submitted, overrides)
    outcome = mod.execute(cmd, args_executed, ex_state, ctx)

    record = %{
      endpoint: ep,
      command: cmd,
      args_submitted: args_submitted,
      args_executed: args_executed,
      ok: match?({:ok, _}, outcome),
      result:
        case outcome do
          {:ok, result} -> result
          {:error, reason} -> %{"error" => inspect(reason)}
        end
    }

    # accumulated in the step task's process dictionary; read back in run_step/5
    Process.put(:genai_approval_calls, [record | Process.get(:genai_approval_calls, [])])
    outcome
  end

  # -- task results ----------------------------------------------------------

  @impl GenServer
  def handle_info({ref, reply}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = cancel_timer(state, :step)
    duration = System.monotonic_time(:millisecond) - state.task.started_at
    step = state.pending

    case reply do
      {:ok, %{env: env2, calls: calls}} ->
        state =
          %{state | env: env2, task: nil, pending: nil, progressed: true}
          |> record_result(step, :completed, calls, duration)

        telemetry(:step, :stop, %{duration: duration}, %{
          run_id: state.run_id,
          step_id: step.id,
          status: :completed
        })

        state = %{state | status: :paused}

        if state.mode in [:next, :run_all] do
          {:noreply, proceed(state)}
        else
          {:noreply, do_pause(state)}
        end

      {:error, reason, calls} ->
        {:noreply, step_failure(state, step, reason, calls, duration)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    state = cancel_timer(state, :step)
    duration = System.monotonic_time(:millisecond) - state.task.started_at
    {:noreply, step_failure(state, state.pending, {:crashed, reason}, [], duration)}
  end

  def handle_info({:step_timeout, ref}, %{task: %{ref: ref, pid: pid}} = state) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    duration = System.monotonic_time(:millisecond) - state.task.started_at
    {:noreply, step_failure(state, state.pending, :timeout, [], duration)}
  end

  def handle_info({:run_timeout, ref}, %{timers: %{run: ref}} = state) do
    if terminal?(state.status) do
      {:noreply, state}
    else
      {:noreply, do_halt(state, "budget_exceeded", :system)}
    end
  end

  def handle_info({:idle_timeout, ref}, %{timers: %{idle: ref}} = state) do
    if state.status in [:paused, :awaiting_permission] do
      {:noreply, do_halt(state, "operator_timeout", :system)}
    else
      {:noreply, state}
    end
  end

  # stale timers / late task messages
  def handle_info(_msg, state), do: {:noreply, state}

  defp step_failure(state, step, reason, calls, duration) do
    state =
      %{state | task: nil, pending_failed: true}
      |> record_result(step, :failed, calls, duration, reason)

    telemetry(:step, :exception, %{duration: duration}, %{
      run_id: state.run_id,
      step_id: step.id,
      reason: reason
    })

    if state.mode == :run_all do
      do_halt(%{state | status: :paused}, "step_failed", :system, %{
        step: step.id,
        error: inspect(reason)
      })
    else
      do_pause(%{state | status: :paused})
    end
  end

  # -- pause / terminal ------------------------------------------------------

  defp do_pause(state) do
    state = %{state | status: :paused, mode: nil, progressed: false}

    emit(state, :paused, %{
      at: state.pending && state.pending.id,
      failed: state.pending_failed
    })
  end

  defp complete(state) do
    {outputs, unavailable} = eval_outputs(state)

    state = %{state | status: :completed}
    state = %{state | result: build_result(state, outputs, unavailable)}

    telemetry(:run, :stop, %{duration: System.monotonic_time(:millisecond) - state.started_at}, %{
      run_id: state.run_id,
      status: :completed
    })

    state
    |> emit(:completed, %{outputs: outputs})
    |> reply_waiters()
  end

  defp do_halt(state, reason, actor, extra \\ %{}) do
    state = kill_task(state)
    at_step = state.pending && state.pending.id

    halt_info =
      %{reason: reason, actor: actor, at_step: at_step}
      |> Map.merge(extra)

    {outputs, unavailable} = eval_outputs(state)

    state = %{state | status: :halted, halt_info: halt_info}
    state = %{state | result: build_result(state, outputs, unavailable)}

    telemetry(:run, :stop, %{duration: System.monotonic_time(:millisecond) - state.started_at}, %{
      run_id: state.run_id,
      status: :halted,
      reason: reason
    })

    state
    |> emit(:halted, halt_info)
    |> reply_waiters()
  end

  defp do_fail(state, reason) do
    state = kill_task(state)

    state = %{
      state
      | status: :failed,
        halt_info: %{reason: inspect(reason), actor: :system, at_step: nil}
    }

    state = %{state | result: build_result(state, %{}, [])}

    state
    |> emit(:failed, %{reason: inspect(reason)})
    |> reply_waiters()
  end

  defp kill_task(%{task: %{ref: ref, pid: pid}} = state) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    cancel_timer(%{state | task: nil}, :step)
  end

  defp kill_task(state), do: state

  defp reply_waiters(state) do
    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, state.result}))
    %{state | waiters: []}
  end

  defp terminal?(status), do: status in [:completed, :halted, :failed]

  # -- results ---------------------------------------------------------------

  defp record_result(state, step, status, calls, duration, reason \\ nil) do
    result = %{
      id: step.id,
      title: step.title,
      status: status,
      calls: calls,
      edited: Map.has_key?(state.overrides, step.id),
      via: state.via,
      error: reason && inspect(reason),
      duration_ms: duration
    }

    state = %{state | results: Map.put(state.results, step.id, result)}

    emit(state, :step_completed, %{
      step: step.id,
      status: status,
      error: result.error,
      calls: Enum.map(calls, &Map.take(&1, [:endpoint, :command, :ok]))
    })
  end

  defp eval_outputs(state) do
    Enum.reduce(state.script.outputs, {%{}, []}, fn out, {acc, unavailable} ->
      case Expr.eval(out.expr, state.env, :forbidden) do
        {:ok, value} -> {Map.put(acc, out.name, value), unavailable}
        {:error, _} -> {Map.put(acc, out.name, "unavailable"), [out.name | unavailable]}
      end
    end)
  end

  defp build_result(state, outputs, unavailable) do
    steps =
      Enum.map(state.script.steps, fn step ->
        case Map.get(state.results, step.id) do
          nil ->
            %{id: step.id, title: step.title, status: :not_reached}

          result ->
            result
        end
      end)

    %{
      contract: "1",
      run_id: state.run_id,
      status: state.status,
      halt: state.halt_info,
      steps: steps,
      branches: state.branch_log,
      edits: state.edits,
      notes: state.notes,
      outputs: outputs,
      outputs_unavailable: Enum.reverse(unavailable),
      grants: state.grants,
      audit_ref: nil
    }
  end

  # -- events / timers / telemetry ------------------------------------------

  defp emit(state, type, payload) do
    seq = state.seq + 1
    event = Map.merge(%{seq: seq, type: type, run_id: state.run_id}, payload)

    if state.subscriber, do: send(state.subscriber, {:genai_approval, state.run_id, event})

    %{state | seq: seq, events: Enum.take([event | state.events], @event_ring)}
  end

  defp arm_timer(state, kind, ms) do
    ref = make_ref()
    Process.send_after(self(), {:"#{kind}_timeout", ref}, ms)
    %{state | timers: Map.put(state.timers, kind, ref)}
  end

  defp arm_step_timer(state, task_ref) do
    Process.send_after(self(), {:step_timeout, task_ref}, state.budgets.step_timeout)
    state
  end

  defp cancel_timer(state, kind) do
    %{state | timers: Map.delete(state.timers, kind)}
  end

  defp reset_idle(state) do
    arm_timer(state, :idle, state.budgets.idle_timeout)
  end

  defp telemetry(scope, event, measurements, meta) do
    :telemetry.execute([:genai_approval, scope, event], measurements, meta)
  end
end
