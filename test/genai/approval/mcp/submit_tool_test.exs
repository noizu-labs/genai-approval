defmodule GenAI.Approval.MCP.SubmitToolTest do
  @moduledoc """
  AC19 — full agent → tool → interactive run → structured result round trip
  over a real in-VM MCP wire boundary. async: false because the submit host
  configuration travels through app env.
  """
  use ExUnit.Case, async: false

  alias GenAI.Approval.Executor.Local
  alias GenAI.Approval.Fixtures
  alias GenAI.Approval.TestMCP.ApprovalServer
  alias Noizu.MCP.Client

  @script """
  {{#endpoint "local"}} transport = "local" {{/endpoint}}
  {{#vars}}
    env    : string = "staging"
    result : object?
  {{/vars}}
  {{#step "Deploy"}}
    {{assign result = call("local", "deploy", env=env)}}
  {{/step}}
  {{#outputs}}
    deployed_to = result.env
  {{/outputs}}
  """

  setup do
    test_pid = self()

    handlers = %{
      "deploy" => fn args, _ctx ->
        send(test_pid, {:deployed, args})
        {:ok, %{"env" => args["env"], "ok" => true}}
      end
    }

    run_opts = [
      executors: %{"local" => {Local, handlers}},
      permission: [store: Fixtures.allow_all_store(), subject: "keith", session_id: "mcp"]
    ]

    Application.put_env(:genai_approval, :submit_host, GenAI.Approval.TestSubmitHost)

    Application.put_env(:genai_approval, :test_submit_cfg, %{
      run_opts: run_opts,
      notify: test_pid
    })

    on_exit(fn ->
      Application.delete_env(:genai_approval, :submit_host)
      Application.delete_env(:genai_approval, :test_submit_cfg)
    end)

    {:ok, client} =
      Client.start_link(
        transport: {:test, server: ApprovalServer},
        client_info: %{name: "test-agent", version: "0.0.1"}
      )

    :ok = Client.await_ready(client)
    on_exit(fn -> catch_exit(Client.close(client)) end)

    %{client: client, test_pid: test_pid}
  end

  test "AC19 — agent submits, operator drives, agent receives the §9 result", %{client: client} do
    # the tool parks while the operator works, so call from a task
    call =
      Task.async(fn ->
        Client.call_tool(client, "submit_approval_script", %{
          "script" => @script,
          "variables" => %{"env" => "prod"}
        })
      end)

    # host notified of the new run — the "operator" (this test) drives it
    assert_receive {:approval_run, run, run_id}, 5_000
    assert is_binary(run_id)

    assert :ok = GenAI.Approval.command(run, :run_all)
    assert_receive {:deployed, %{"env" => "prod"}}, 5_000

    assert {:ok, result} = Task.await(call, 10_000)
    refute result.is_error

    # sanitized §9 contract as structured content
    payload = result.structured
    assert payload["contract"] == "1"
    assert payload["status"] == "completed"
    assert payload["run_id"] == run_id
    assert payload["outputs"] == %{"deployed_to" => "prod"}
    assert [step] = payload["steps"]
    assert step["status"] == "completed"
    assert [call_rec] = step["calls"]
    assert call_rec["args_executed"] == %{"env" => "prod"}
  end

  test "halt reason and notes flow back to the agent", %{client: client} do
    call =
      Task.async(fn ->
        Client.call_tool(client, "submit_approval_script", %{"script" => @script})
      end)

    assert_receive {:approval_run, run, _run_id}, 5_000
    assert :ok = GenAI.Approval.command(run, {:annotate, "run", "wrong window"})
    assert :ok = GenAI.Approval.command(run, {:halt, "change freeze"})

    assert {:ok, result} = Task.await(call, 10_000)
    refute result.is_error

    payload = result.structured
    assert payload["status"] == "halted"
    assert payload["halt"]["reason"] == "change freeze"
    assert payload["halt"]["actor"] == "operator"
    assert [%{"text" => "wrong window"}] = Enum.map(payload["notes"], &Map.take(&1, ["text"]))
    assert [%{"status" => "not_reached"}] = Enum.map(payload["steps"], &Map.take(&1, ["status"]))
  end

  test "script rejection returns a tool execution error with line info", %{client: client} do
    {:ok, result} =
      Client.call_tool(client, "submit_approval_script", %{
        "script" => "{{#step \"s\"}} {{call \"ghost\" \"cmd\"}} {{/step}}"
      })

    assert result.is_error

    text =
      result.content
      |> Enum.map(&Map.get(&1, :text))
      |> Enum.join("\n")

    assert text =~ "script rejected"
    assert text =~ "undeclared_endpoint"
    assert text =~ "line"
  end

  test "host refusal surfaces as a tool error", %{client: client} do
    Application.put_env(:genai_approval, :test_submit_cfg, %{
      refuse: :submissions_disabled,
      notify: self()
    })

    {:ok, result} = Client.call_tool(client, "submit_approval_script", %{"script" => @script})
    assert result.is_error

    text = result.content |> Enum.map(&Map.get(&1, :text)) |> Enum.join("\n")
    assert text =~ "submissions_disabled"
  end
end
