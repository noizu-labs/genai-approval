defmodule GenAI.Approval.Permission.Store.DETS do
  @moduledoc """
  Durable permission-rule store (M3): DETS-backed, survives restarts.

  Start under a supervisor with a file path:

      {GenAI.Approval.Permission.Store.DETS,
       name: MyApp.PermissionStore, path: "/var/lib/myapp/permission_rules.dets"}

  Then address it as `{Store.DETS, MyApp.PermissionStore}` in run options.
  Semantics match `Store.ETS`: `:call`-scoped rules are never persisted,
  subject/session filtering applies, expired `{:until, _}` rules are pruned
  lazily on read. Writes are followed by `:dets.sync/1` so a crash cannot
  lose an `always`/`block` grant.

  For multi-node or per-user rules shared across apps, implement the
  `GenAI.Approval.Permission.Store` behaviour over your own storage
  (e.g. a `noizu_labs_entities` entity) — this module is the single-node
  durable default.
  """

  use GenServer

  alias GenAI.Approval.Permission
  alias GenAI.Approval.Permission.Rule

  @behaviour GenAI.Approval.Permission.Store

  # -- lifecycle -------------------------------------------------------------

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :table_name, name), name: name)
  end

  @impl GenServer
  def init(opts) do
    path = opts |> Keyword.fetch!(:path) |> String.to_charlist()
    table = Keyword.fetch!(opts, :table_name)

    case :dets.open_file(table, file: path, type: :set) do
      {:ok, table} -> {:ok, %{table: table}}
      {:error, reason} -> {:stop, {:dets_open_failed, reason}}
    end
  end

  @impl GenServer
  def terminate(_reason, %{table: table}) do
    :dets.close(table)
  end

  # -- Store behaviour (callable with the table name as ref) -----------------

  @impl GenAI.Approval.Permission.Store
  def put(_table, %Rule{scope: :call}), do: {:error, :call_scope_not_stored}

  def put(table, %Rule{} = rule) do
    :ok = :dets.insert(table, {rule.id, rule})
    :ok = :dets.sync(table)
    :ok
  end

  @impl GenAI.Approval.Permission.Store
  def revoke(table, rule_id) do
    :ok = :dets.delete(table, rule_id)
    :ok = :dets.sync(table)
    :ok
  end

  @impl GenAI.Approval.Permission.Store
  def rules(table, subject, session_id) do
    now = DateTime.utc_now()

    rules =
      table
      |> dets_all()
      |> Enum.filter(fn rule ->
        cond do
          Permission.expired?(rule, now) ->
            :dets.delete(table, rule.id)
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

  @impl GenAI.Approval.Permission.Store
  def list(table) do
    {:ok, dets_all(table)}
  end

  defp dets_all(table) do
    :dets.foldl(fn {_id, rule}, acc -> [rule | acc] end, [], table)
  end
end
