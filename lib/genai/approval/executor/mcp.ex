if Code.ensure_loaded?(Noizu.MCP.Client) do
  defmodule GenAI.Approval.Executor.MCP do
    @moduledoc """
    Executes script calls against MCP servers via `Noizu.MCP.Client`
    (M4, PRD §6.4 adapter 1). One client per declared endpoint, started
    under `GenAI.Approval.ClientSupervisor` and closed when the run
    terminates (R6.7).

    Per-alias config (the second element of `{Executor.MCP, config}`):

      * `:transport` — explicit `Noizu.MCP.Client` transport tuple; overrides
        the script's declaration (used for stdio command config and tests)
      * `:credentials` — how preamble `credential("id")` references resolve
        to client auth: a map `%{"id" => {StrategyMod, opts}}` or a
        1-arity fun returning `{:ok, auth} | {:error, reason}`
      * `:client_opts` — extra `Noizu.MCP.Client` options (`:handler`,
        `:client_info`, `:request_timeout`, …)
      * `:ready_timeout` — handshake wait (default 10s)
      * `:call_timeout` — per tool call (default: client `request_timeout`)

    Script transports map as:

      * `"streamable_http"` — `{:streamable_http, url: <declared url>, auth: <resolved>}`
      * `"stdio"` — requires `:transport` in config (commands are host
        configuration, never script input)

    `describe/2` serves the cached `tools/list` entry so UIs can render
    argument forms and risk badges (`destructiveHint` etc. are untrusted
    hints, per S10 — never a substitute for permission rules).
    """

    @behaviour GenAI.Approval.Executor

    alias Noizu.MCP.Client
    alias Noizu.MCP.Types.ToolResult

    @impl true
    def prepare(decl, config) when is_map(config) do
      with {:ok, transport} <- transport_for(decl, config),
           {:ok, client} <- start_client(transport, config) do
        case Client.await_ready(client, Map.get(config, :ready_timeout, 10_000)) do
          :ok ->
            {:ok,
             %{
               client: client,
               endpoint: decl.name,
               call_timeout: Map.get(config, :call_timeout),
               tools: fetch_tools(client)
             }}

          {:error, reason} ->
            Client.close(client)
            {:error, {:handshake_failed, decl.name, reason}}
        end
      end
    end

    def prepare(decl, config), do: {:error, {:invalid_mcp_config, decl.name, config}}

    @impl true
    def execute(command, args, state, _run_ctx) do
      opts = if state.call_timeout, do: [timeout: state.call_timeout], else: []

      case Client.call_tool(state.client, command, args, opts) do
        {:ok, %ToolResult{is_error: true} = result} ->
          {:error, {:tool_error, result_text(result)}}

        {:ok, %ToolResult{structured: structured} = result} ->
          {:ok, structured || %{"text" => result_text(result)}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def describe(command, state) do
      case Map.fetch(state.tools, command) do
        {:ok, tool} ->
          {:ok, %{schema: tool.input_schema, annotations: tool.annotations || %{}}}

        :error ->
          {:ok, %{schema: nil, annotations: %{}}}
      end
    end

    @impl true
    def close(state) do
      try do
        Client.close(state.client)
      catch
        :exit, _ -> :ok
      end

      :ok
    end

    # -- wiring ----------------------------------------------------------------

    defp transport_for(_decl, %{transport: transport}), do: {:ok, transport}

    defp transport_for(%{transport: "streamable_http"} = decl, config) do
      cond do
        decl.url == nil ->
          {:error, {:missing_url, decl.name}}

        true ->
          with {:ok, auth} <- resolve_auth(decl.auth, config) do
            opts = [url: decl.url] ++ if auth, do: [auth: auth], else: []
            {:ok, {:streamable_http, opts}}
          end
      end
    end

    defp transport_for(%{transport: "stdio"} = decl, _config) do
      # stdio commands are host configuration — supply config :transport
      {:error, {:stdio_requires_host_transport, decl.name}}
    end

    defp transport_for(decl, _config) do
      {:error, {:unsupported_transport, decl.name, decl.transport}}
    end

    defp resolve_auth(nil, _config), do: {:ok, nil}

    defp resolve_auth({:credential, id}, config) do
      case Map.get(config, :credentials) do
        fun when is_function(fun, 1) ->
          fun.(id)

        %{} = credentials ->
          case Map.fetch(credentials, id) do
            {:ok, auth} -> {:ok, auth}
            :error -> {:error, {:unknown_credential, id}}
          end

        nil ->
          {:error, {:unknown_credential, id}}
      end
    end

    defp start_client(transport, config) do
      opts = [transport: transport] ++ Map.get(config, :client_opts, [])

      spec = %{
        id: Client,
        start: {Client, :start_link, [opts]},
        restart: :temporary
      }

      DynamicSupervisor.start_child(GenAI.Approval.ClientSupervisor, spec)
    end

    defp fetch_tools(client) do
      case Client.list_tools(client) do
        {:ok, tools} -> Map.new(tools, &{&1.name, &1})
        {:error, _} -> %{}
      end
    end

    defp result_text(%ToolResult{content: content}) do
      content
      |> Enum.map(fn
        %{type: :text, text: text} when is_binary(text) -> text
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    end
  end
end
