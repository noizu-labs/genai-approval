defmodule GenAI.Approval.Permission.Store do
  @moduledoc """
  Pluggable persistence for permission rules.

  A store is addressed as `{module, ref}` — `ref` is whatever the module
  needs (an ETS table, a repo name, a pid). Session-scoped rules are tagged
  with `session_id` and only returned for that session; `:call`-scoped
  approvals are transient and never stored.
  """

  alias GenAI.Approval.Permission.Rule

  @callback put(ref :: term(), Rule.t()) :: :ok | {:error, term()}
  @callback revoke(ref :: term(), rule_id :: String.t()) :: :ok | {:error, term()}
  @doc "All unexpired candidate rules for a subject + session (global rules included)."
  @callback rules(ref :: term(), subject :: String.t() | nil, session_id :: String.t() | nil) ::
              {:ok, [Rule.t()]}
  @callback list(ref :: term()) :: {:ok, [Rule.t()]}
end
