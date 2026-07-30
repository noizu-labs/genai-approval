defmodule GenAI.Approval do
  @moduledoc """
  Interactive approval scripts for agents.

  An agent submits a small, non-Turing-complete script (endpoint preamble,
  typed variables, steps with conditionals, declared outputs); a human drives
  it call-by-call — step / next / run-all / edit / halt — with breakpoints and
  scoped allow/block permission rules. The structured result (per-step
  outcomes, notes, edit diffs, outputs, halt reason, grants) returns to the
  calling agent.

      {:ok, script} = GenAI.Approval.load(source)

      {:ok, run} =
        GenAI.Approval.start_run(script,
          executors: %{"notify" => {GenAI.Approval.Executor.Local, handlers}},
          subscriber: self(),
          permission: [store: {Store.ETS, MyStore}, subject: "keith", session_id: "sess-1"]
        )

      :ok = GenAI.Approval.command(run, :step)
      {:ok, result} = GenAI.Approval.await(run)
  """

  alias GenAI.Approval.{Parser, Runner, Script}

  @doc """
  Parse + statically check a script source.

  Options: `:max_script_size` (bytes, default 64 KiB), `:max_steps`
  (default 50). Returns `{:ok, %Script{}}` or `{:error, [%Error{}]}`.
  """
  @spec load(String.t(), keyword()) :: {:ok, Script.t()} | {:error, [GenAI.Approval.Error.t()]}
  defdelegate load(source, opts \\ []), to: Parser, as: :parse

  @doc """
  Start an interactive run under the library's supervisor.

  Options (see `GenAI.Approval.Runner`): `:executors` (required — map of
  endpoint alias to `{module, config}`), `:subscriber`, `:variables`,
  `:permission`, `:budgets`, `:run_id`.
  """
  @spec start_run(Script.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_run(%Script{} = script, opts \\ []) do
    spec = %{
      id: Runner,
      start: {Runner, :start_link, [Keyword.put(opts, :script, script)]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(GenAI.Approval.RunSupervisor, spec)
  end

  @doc "Issue a control command to a run (pid or run id)."
  def command(run, cmd), do: Runner.command(resolve(run), cmd)

  @doc "Block until the run terminates; returns `{:ok, result}` (PRD §9 contract)."
  def await(run, timeout \\ :infinity), do: Runner.await(resolve(run), timeout)

  @doc "Snapshot of run status."
  def info(run), do: Runner.info(resolve(run))

  @doc "Replay buffer of run events (oldest first, bounded ring)."
  def events(run), do: Runner.events(resolve(run))

  @doc "Add a live event subscriber (defaults to the caller)."
  def subscribe(run, pid \\ self()), do: Runner.subscribe(resolve(run), pid)

  @doc "UI-facing state snapshot; feed to `GenAI.Approval.Render.model/1`."
  def snapshot(run), do: Runner.snapshot(resolve(run))

  defp resolve(pid) when is_pid(pid), do: pid

  defp resolve(run_id) when is_binary(run_id) do
    case Registry.lookup(GenAI.Approval.Registry, run_id) do
      [{pid, _}] -> pid
      [] -> raise ArgumentError, "no run registered as #{inspect(run_id)}"
    end
  end
end
