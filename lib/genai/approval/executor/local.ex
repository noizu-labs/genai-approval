defmodule GenAI.Approval.Executor.Local do
  @moduledoc """
  Executes script calls against host-registered native handlers — no network,
  no MCP. Config is a map of `"command" => handler`, where handler is a
  2-arity fun `(args, run_ctx)` returning `{:ok, result} | {:error, reason}`,
  or `{module, function}`.
  """

  @behaviour GenAI.Approval.Executor

  @impl true
  def prepare(_endpoint_decl, handlers) when is_map(handlers), do: {:ok, handlers}
  def prepare(_endpoint_decl, other), do: {:error, {:invalid_local_config, other}}

  @impl true
  def execute(command, args, handlers, run_ctx) do
    case Map.fetch(handlers, command) do
      {:ok, fun} when is_function(fun, 2) ->
        fun.(args, run_ctx)

      {:ok, {mod, fun}} when is_atom(mod) and is_atom(fun) ->
        apply(mod, fun, [args, run_ctx])

      :error ->
        {:error, {:unknown_command, command}}
    end
  end

  @impl true
  def describe(_command, _handlers), do: {:ok, %{schema: nil, annotations: %{}}}

  @impl true
  def close(_handlers), do: :ok
end
