defmodule GenAI.Approval.TestMCP.AlphaEcho do
  @moduledoc false
  use Noizu.MCP.Server.Tool,
    name: "alpha.echo",
    description: "Echo a message back"

  input do
    field(:msg, :string, required: true)
  end

  @impl true
  def call(%{msg: msg}, _ctx), do: {:ok, %{"echo" => msg, "server" => "alpha"}}
end

defmodule GenAI.Approval.TestMCP.AlphaBoom do
  @moduledoc false
  use Noizu.MCP.Server.Tool,
    name: "alpha.boom",
    description: "Always fails"

  @impl true
  def call(_args, _ctx), do: {:error, "boom: tool refused"}
end

defmodule GenAI.Approval.TestMCP.BetaDouble do
  @moduledoc false
  use Noizu.MCP.Server.Tool,
    name: "beta.double",
    description: "Double a number",
    annotations: [read_only_hint: true]

  input do
    field(:n, :number, required: true)
  end

  @impl true
  def call(%{n: n}, _ctx), do: {:ok, %{"doubled" => n * 2, "server" => "beta"}}
end

defmodule GenAI.Approval.TestMCP.Alpha do
  @moduledoc false
  use Noizu.MCP.Server, name: "alpha", version: "0.0.1"

  tool(GenAI.Approval.TestMCP.AlphaEcho)
  tool(GenAI.Approval.TestMCP.AlphaBoom)
end

defmodule GenAI.Approval.TestMCP.Beta do
  @moduledoc false
  use Noizu.MCP.Server, name: "beta", version: "0.0.1"

  tool(GenAI.Approval.TestMCP.BetaDouble)
end

defmodule GenAI.Approval.TestMCP.ApprovalServer do
  @moduledoc false
  use Noizu.MCP.Server,
    name: "approval",
    version: "0.0.1",
    instructions: "Submit approval scripts with submit_approval_script."

  tool(GenAI.Approval.MCP.SubmitApprovalScript)
end

defmodule GenAI.Approval.TestSubmitHost do
  @moduledoc false
  @behaviour GenAI.Approval.SubmitHost

  # Test configuration travels via app env:
  #   Application.put_env(:genai_approval, :test_submit_cfg, %{run_opts: ..., notify: pid})
  defp cfg, do: Application.fetch_env!(:genai_approval, :test_submit_cfg)

  @impl true
  def run_options(_script, _meta) do
    case cfg() do
      %{refuse: reason} -> {:error, reason}
      %{run_opts: run_opts} -> {:ok, run_opts}
    end
  end

  @impl true
  def on_run(run, run_id, _meta) do
    send(cfg().notify, {:approval_run, run, run_id})
    :ok
  end
end
