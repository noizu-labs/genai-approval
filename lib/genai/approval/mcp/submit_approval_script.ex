if Code.ensure_loaded?(Noizu.MCP.Server.Tool) do
  defmodule GenAI.Approval.MCP.SubmitApprovalScript do
    @moduledoc """
    The v1 interop surface (PRD §10): a standard MCP tool any client can
    call to submit an approval script. Register it on a `Noizu.MCP.Server`:

        tool GenAI.Approval.MCP.SubmitApprovalScript

    and configure the host that maps submissions to runs:

        config :genai_approval, :submit_host, MyApp.ApprovalHost

    The tool loads the script (rejections return as a tool execution error
    with line/column details), asks the `GenAI.Approval.SubmitHost` for run
    options, starts the run, notifies the host (`on_run/3` — mount your UI),
    then **parks until the run terminates** and returns the sanitized §9
    result as structured content. Callers should use a generous or infinite
    per-call timeout, exactly like the MCP Inspector's parked calls.
    """

    use Noizu.MCP.Server.Tool,
      name: "submit_approval_script",
      description:
        "Submit a multi-step approval script for interactive human review. " <>
          "The script (endpoint preamble, typed vars, steps with conditionals, outputs) " <>
          "is shown to an operator who steps through it call-by-call; the structured " <>
          "result (per-step outcomes, notes, edits, declared outputs, halt reason) is returned.",
      annotations: [open_world_hint: true]

    input_schema(%{
      "type" => "object",
      "properties" => %{
        "script" => %{
          "type" => "string",
          "description" => "Approval-script source (handlebars-style; see genai_approval docs)"
        },
        "variables" => %{
          "type" => "object",
          "description" => "Initial variable bindings, merged over script defaults",
          "additionalProperties" => true
        },
        "timeout_ms" => %{
          "type" => "integer",
          "description" => "Max time to wait for the operator (default: no limit)"
        }
      },
      "required" => ["script"],
      "additionalProperties" => false
    })

    alias GenAI.Approval
    alias GenAI.Approval.Result

    @impl true
    def call(args, ctx) do
      source = arg(args, "script")
      variables = arg(args, "variables") || %{}
      timeout = arg(args, "timeout_ms") || :infinity

      with {:ok, host} <- fetch_host(),
           {:ok, script} <- load(source),
           meta = %{session_id: ctx.session_id, variables: variables},
           {:ok, run_opts} <- host.run_options(script, meta),
           run_opts = Keyword.update(run_opts, :variables, variables, &Map.merge(&1, variables)),
           {:ok, run} <- Approval.start_run(script, run_opts) do
        %{run_id: run_id} = Approval.info(run)

        if function_exported?(host, :on_run, 3) do
          host.on_run(run, run_id, meta)
        end

        try do
          {:ok, result} = Approval.await(run, timeout)
          {:ok, Result.sanitize(result)}
        catch
          :exit, _ ->
            # caller-imposed wait expired; halt the run so nothing dangles
            _ = Approval.command(run, {:halt, "submission timeout"})
            {:error, "approval wait timed out after #{timeout}ms"}
        end
      else
        {:error, {:load, errors}} ->
          {:error, "script rejected:\n" <> format_errors(errors)}

        {:error, reason} ->
          {:error, "submission failed: #{inspect(reason)}"}
      end
    end

    # args arrive string-keyed (raw input_schema) but tolerate atom keys too
    defp arg(args, key) do
      atom_key =
        try do
          String.to_existing_atom(key)
        rescue
          ArgumentError -> nil
        end

      args[key] || (atom_key && args[atom_key]) || nil
    end

    defp fetch_host do
      case Application.get_env(:genai_approval, :submit_host) do
        nil -> {:error, :submit_host_not_configured}
        host -> {:ok, host}
      end
    end

    defp load(source) when is_binary(source) do
      case Approval.load(source) do
        {:ok, script} -> {:ok, script}
        {:error, errors} -> {:error, {:load, errors}}
      end
    end

    defp load(_), do: {:error, {:load, []}}

    defp format_errors(errors) do
      Enum.map_join(errors, "\n", fn error ->
        "- [#{error.code}] line #{error.line || "?"}, col #{error.column || "?"}: #{error.message}"
      end)
    end
  end
end
