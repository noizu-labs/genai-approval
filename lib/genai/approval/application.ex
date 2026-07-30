defmodule GenAI.Approval.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: GenAI.Approval.Registry},
      {Task.Supervisor, name: GenAI.Approval.TaskSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: GenAI.Approval.RunSupervisor},
      {DynamicSupervisor, strategy: :one_for_one, name: GenAI.Approval.ClientSupervisor},
      {GenAI.Approval.Permission.Store.ETS, name: GenAI.Approval.PermissionStore}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GenAI.Approval.Supervisor)
  end
end
