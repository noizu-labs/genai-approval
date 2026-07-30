defmodule GenAI.Approval.SubmitHost do
  @moduledoc """
  Behaviour the host application implements to accept agent-submitted
  approval scripts (the v1 interop surface, PRD §10).

  Configure the implementing module:

      config :genai_approval, :submit_host, MyApp.ApprovalHost

  When an agent calls the `submit_approval_script` MCP tool, the tool loads
  the script and asks the host for run options — this is where the host maps
  the script's declared endpoints to executors, resolves `credential("id")`
  references, picks the permission store/subject/session, and sets budgets.
  `on_run/3` is the host's cue to surface the run to an operator (mount the
  LiveView, ping the voice surface, …). The tool call then parks until the
  run terminates and returns the sanitized §9 result to the agent.
  """

  alias GenAI.Approval.Script

  @doc """
  Map a loaded script to `GenAI.Approval.start_run/2` options.

  `meta` carries submission context (e.g. `:session_id`, `:variables`).
  Return `{:error, reason}` to refuse the submission (the agent sees a tool
  execution error).
  """
  @callback run_options(script :: Script.t(), meta :: map()) ::
              {:ok, keyword()} | {:error, term()}

  @doc "A run has started — surface it to the operator."
  @callback on_run(run :: pid(), run_id :: String.t(), meta :: map()) :: :ok

  @optional_callbacks on_run: 3
end
