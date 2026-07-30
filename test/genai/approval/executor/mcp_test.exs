defmodule GenAI.Approval.Executor.MCPTest do
  @moduledoc "AC14/AC16 — MCP executor over in-VM noizu_mcp servers."
  use ExUnit.Case, async: true

  alias GenAI.Approval.Executor.MCP, as: MCPExec
  alias GenAI.Approval.Fixtures
  alias GenAI.Approval.TestMCP.{Alpha, Beta}

  @two_server_script """
  {{#endpoint "alpha"}}
    transport = "streamable_http"
    url       = "https://alpha.internal/mcp"
    auth      = credential("alpha-bot")
  {{/endpoint}}
  {{#endpoint "beta"}}
    transport = "streamable_http"
    url       = "https://beta.internal/mcp"
  {{/endpoint}}
  {{#vars}}
    greeting : object?
    math     : object?
  {{/vars}}
  {{#step "Echo on alpha"}}
    {{assign greeting = call("alpha", "alpha.echo", msg="hello")}}
  {{/step}}
  {{#step "Double on beta"}}
    {{assign math = call("beta", "beta.double", n=21)}}
  {{/step}}
  {{#outputs}}
    echoed  = greeting.echo
    servers = [greeting.server, math.server]
    answer  = math.doubled
  {{/outputs}}
  """

  defp start_two_server_run!(opts \\ []) do
    {:ok, script} = GenAI.Approval.load(@two_server_script)

    GenAI.Approval.start_run(
      script,
      Keyword.merge(
        [
          executors: %{
            "alpha" => {MCPExec, %{transport: {:test, server: Alpha}}},
            "beta" => {MCPExec, %{transport: {:test, server: Beta}}}
          },
          subscriber: self(),
          permission: [store: Fixtures.allow_all_store(), subject: "t", session_id: "s"]
        ],
        opts
      )
    )
  end

  defp eventually(fun, tries \\ 100) do
    fun.()
  rescue
    e in [ExUnit.AssertionError] ->
      if tries > 0 do
        Process.sleep(10)
        eventually(fun, tries - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  test "AC14 — one script drives two distinct MCP servers; clients torn down after" do
    {:ok, run} = start_two_server_run!()

    assert :ok = GenAI.Approval.command(run, :run_all)
    assert {:ok, result} = GenAI.Approval.await(run, 10_000)

    assert result.status == :completed

    assert result.outputs == %{
             "echoed" => "hello",
             "servers" => ["alpha", "beta"],
             "answer" => 42
           }

    # structuredContent round-tripped through the wire boundary
    s1 = Enum.find(result.steps, &(&1.id == "s1"))
    assert [call] = s1.calls
    assert call.result["echo"] == "hello"

    # per-run clients closed at terminal state (R6.7)
    eventually(fn ->
      assert DynamicSupervisor.count_children(GenAI.Approval.ClientSupervisor).active == 0
    end)
  end

  test "tool isError becomes a step failure, not a crash" do
    source = """
    {{#endpoint "alpha"}}
      transport = "streamable_http"
      url = "https://alpha.internal/mcp"
    {{/endpoint}}
    {{#step "boom"}}
      {{call "alpha" "alpha.boom"}}
    {{/step}}
    """

    {:ok, script} = GenAI.Approval.load(source)

    {:ok, run} =
      GenAI.Approval.start_run(script,
        executors: %{"alpha" => {MCPExec, %{transport: {:test, server: Alpha}}}},
        subscriber: self(),
        permission: [store: Fixtures.allow_all_store(), subject: "t", session_id: "s"]
      )

    assert :ok = GenAI.Approval.command(run, :step)

    assert_receive {:genai_approval, _,
                    %{type: :step_completed, step: "s1", status: :failed} = ev},
                   5_000

    assert ev.error =~ "tool_error"
    assert ev.error =~ "boom: tool refused"

    # terminalize so the per-run client is torn down (test isolation)
    assert :ok = GenAI.Approval.command(run, {:halt, "done testing"})
    assert {:ok, %{status: :halted}} = GenAI.Approval.await(run, 5_000)
  end

  test "describe/2 serves cached tool schemas and annotations" do
    {:ok, script} =
      GenAI.Approval.load("""
      {{#endpoint "beta"}}
        transport = "streamable_http"
        url = "https://beta.internal/mcp"
      {{/endpoint}}
      {{#step "s"}} {{call "beta" "beta.double" n=1}} {{/step}}
      """)

    [decl] = Map.values(script.endpoints)
    {:ok, state} = MCPExec.prepare(decl, %{transport: {:test, server: Beta}})

    assert {:ok, %{schema: schema, annotations: annotations}} =
             MCPExec.describe("beta.double", state)

    assert schema["properties"]["n"]["type"] == "number"
    assert annotations[:read_only_hint] == true or annotations["readOnlyHint"] == true

    assert {:ok, %{schema: nil}} = MCPExec.describe("ghost.tool", state)
    assert :ok = MCPExec.close(state)
  end

  test "AC16 — unresolvable credential fails at start, before any client spawns" do
    {:ok, script} =
      GenAI.Approval.load("""
      {{#endpoint "alpha"}}
        transport = "streamable_http"
        url  = "https://alpha.internal/mcp"
        auth = credential("ghost-cred")
      {{/endpoint}}
      {{#step "s"}} {{call "alpha" "alpha.echo" msg="x"}} {{/step}}
      """)

    assert {:error, {:executor_error, {"alpha", {:unknown_credential, "ghost-cred"}}}} =
             GenAI.Approval.start_run(script,
               executors: %{"alpha" => {MCPExec, %{credentials: %{}}}}
             )
  end

  test "unsupported script transport is rejected at start" do
    {:ok, script} =
      GenAI.Approval.load("""
      {{#endpoint "alpha"}}
        transport = "carrier-pigeon"
      {{/endpoint}}
      {{#step "s"}} {{call "alpha" "alpha.echo" msg="x"}} {{/step}}
      """)

    assert {:error,
            {:executor_error, {"alpha", {:unsupported_transport, "alpha", "carrier-pigeon"}}}} =
             GenAI.Approval.start_run(script, executors: %{"alpha" => {MCPExec, %{}}})
  end
end
