defmodule GenAI.Approval.Host do
  @moduledoc """
  Behaviour a host application implements to surface approval runs
  (PRD §7.2). Mirrors the proven park/respond split: the engine calls
  `present/2` and streams `on_event/3`; the host answers by issuing
  `GenAI.Approval.command/2`.

  Voice hosts implement this without any visual surface — the engine
  enforces `confirm` phrases and grant-scope acknowledgment regardless
  of presentation (R7.4).
  """

  @type session_ctx :: term()
  @type presentation_ref :: term()

  @doc "A run is ready for the operator; return a handle for later events."
  @callback present(run_summary :: map(), session_ctx()) ::
              {:ok, presentation_ref()} | {:error, term()}

  @doc "A run event (see `GenAI.Approval.Runner` event stream)."
  @callback on_event(event :: map(), presentation_ref(), session_ctx()) :: :ok

  @doc "Resolve a preamble `credential(\"id\")` reference to executor auth config."
  @callback resolve_credential(credential_id :: String.t(), session_ctx()) ::
              {:ok, term()} | {:error, :unknown_credential}

  @optional_callbacks resolve_credential: 2
end
