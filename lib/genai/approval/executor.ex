defmodule GenAI.Approval.Executor do
  @moduledoc """
  Behaviour for script execution targets (PRD §6.4).

  Adapters: `GenAI.Approval.Executor.Local` (native handlers, in-process);
  an MCP adapter over `noizu_mcp` clients arrives with milestone M4.
  """

  @type endpoint_decl :: GenAI.Approval.Script.Endpoint.t()
  @type run_ctx :: %{run_id: String.t(), step_id: String.t(), env: map()}

  @callback prepare(endpoint_decl(), config :: term()) ::
              {:ok, state :: term()} | {:error, term()}

  @callback execute(command :: String.t(), args :: map(), state :: term(), run_ctx()) ::
              {:ok, result :: term()} | {:error, term()}

  @doc "Optional metadata for UIs: arg schema for edit forms, risk annotations."
  @callback describe(command :: String.t(), state :: term()) ::
              {:ok, %{schema: map() | nil, annotations: map()}} | {:error, term()}

  @callback close(state :: term()) :: :ok

  @optional_callbacks describe: 2, close: 1
end
