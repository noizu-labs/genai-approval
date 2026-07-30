defmodule GenAI.Approval.Permission.Store.ETS do
  @moduledoc """
  Default in-memory rule store.

  Start it under a supervisor (`{Store.ETS, name: MyStore}`) or create a
  caller-owned table with `new/0` in tests. Expired `{:until, _}` rules are
  pruned lazily on read.
  """

  use GenServer

  alias GenAI.Approval.Permission
  alias GenAI.Approval.Permission.Rule

  @behaviour GenAI.Approval.Permission.Store

  # -- lifecycle -------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :table_name, name), name: name)
  end

  @impl GenServer
  def init(opts) do
    table = :ets.new(Keyword.fetch!(opts, :table_name), [:set, :public, :named_table])
    {:ok, %{table: table}}
  end

  @doc "Create an anonymous caller-owned table (tests)."
  def new do
    :ets.new(:genai_approval_rules, [:set, :public])
  end

  # -- Store behaviour -------------------------------------------------------

  @impl true
  def put(_table, %Rule{scope: :call}), do: {:error, :call_scope_not_stored}

  def put(table, %Rule{} = rule) do
    true = :ets.insert(table, {rule.id, rule})
    :ok
  end

  @impl true
  def revoke(table, rule_id) do
    true = :ets.delete(table, rule_id)
    :ok
  end

  @impl true
  def rules(table, subject, session_id) do
    now = DateTime.utc_now()

    rules =
      table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, rule} -> rule end)
      |> Enum.filter(fn rule ->
        cond do
          Permission.expired?(rule, now) ->
            :ets.delete(table, rule.id)
            false

          rule.subject != nil and rule.subject != subject ->
            false

          rule.scope == :session and rule.session_id != session_id ->
            false

          true ->
            true
        end
      end)

    {:ok, rules}
  end

  @impl true
  def list(table) do
    {:ok, table |> :ets.tab2list() |> Enum.map(fn {_id, rule} -> rule end)}
  end
end
