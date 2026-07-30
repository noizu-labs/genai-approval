if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule GenAI.Approval.Live.RunView do
    @moduledoc """
    Phoenix LiveView reference UI for an approval run (PRD R7.1).

    Mount with the run id in the session:

        live_render(conn, GenAI.Approval.Live.RunView, session: %{"run_id" => run_id})

    Renders the shared `GenAI.Approval.Render` model: syntax-highlighted
    source with a breakpoint gutter, taken/untaken branch dimming, the step
    list, the permission prompt (approve / allow / block × scope), and the
    navbar (step · next · run all · retry/skip · halt + reason). All script
    and operator content is HEEx-interpolated, so it renders escaped (S9).
    """

    use Phoenix.LiveView

    alias GenAI.Approval
    alias GenAI.Approval.Render

    @impl true
    def mount(_params, session, socket) do
      run = Map.fetch!(session, "run_id")

      if connected?(socket), do: Approval.subscribe(run)

      {:ok, refresh(assign(socket, run: run, error: nil))}
    end

    @impl true
    def handle_info({:genai_approval, _run_id, _event}, socket) do
      {:noreply, refresh(socket)}
    end

    @impl true
    def handle_event("cmd", %{"cmd" => cmd}, socket) do
      command =
        case cmd do
          "step" -> :step
          "next" -> :next
          "run_all" -> :run_all
          "approve" -> :approve
          "decline" -> :decline
          "retry" -> :retry
          "skip" -> :skip
          _ -> nil
        end

      run_command(socket, command)
    end

    def handle_event("halt", params, socket) do
      reason =
        case String.trim(params["reason"] || "") do
          "" -> nil
          reason -> reason
        end

      run_command(socket, {:halt, reason})
    end

    def handle_event("grant", %{"effect" => effect, "scope" => scope}, socket) do
      effect = if effect == "block", do: :block, else: :allow

      scope =
        case scope do
          "session" -> :session
          "hour" -> {:for, 3600}
          "always" -> :always
          _ -> :session
        end

      run_command(socket, {:grant, effect, scope})
    end

    def handle_event("toggle_bp", %{"step" => step_id}, socket) do
      step = Enum.find(socket.assigns.model.steps, &(&1.id == step_id))

      command =
        if step && step.breakpoint,
          do: {:clear_breakpoint, step_id},
          else: {:set_breakpoint, step_id}

      run_command(socket, command)
    end

    def handle_event("annotate", %{"target" => target, "text" => text}, socket) do
      if String.trim(text) == "" do
        {:noreply, socket}
      else
        run_command(socket, {:annotate, target, text})
      end
    end

    def handle_event("edit_var", %{"name" => name, "value" => raw}, socket) do
      value =
        case Jason.decode(raw) do
          {:ok, decoded} -> decoded
          {:error, _} -> raw
        end

      run_command(socket, {:edit, {:var, name}, value})
    end

    defp run_command(socket, nil), do: {:noreply, socket}

    defp run_command(socket, command) do
      socket =
        case Approval.command(socket.assigns.run, command) do
          :ok -> assign(socket, error: nil)
          {:error, reason} -> assign(socket, error: inspect(reason))
        end

      {:noreply, refresh(socket)}
    end

    defp refresh(socket) do
      assign(socket, model: Render.model(Approval.snapshot(socket.assigns.run)))
    end

    attr(:model, :map, required: true)

    defp status_badge(assigns) do
      ~H"""
      <span class={"gaa-badge gaa-status-#{@model.status}"}>{@model.status}</span>
      """
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div class="gaa-run" id={"gaa-run-#{@model.run_id}"}>
        <style>
          .gaa-run { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px;
                     color: #e6edf3; background: #0d1117; border: 1px solid #30363d;
                     border-radius: 8px; padding: 12px; max-width: 980px; }
          .gaa-run .gaa-head { display: flex; gap: 10px; align-items: center; margin-bottom: 8px; }
          .gaa-run .gaa-badge { padding: 1px 8px; border-radius: 10px; background: #21262d; }
          .gaa-run .gaa-status-completed { background: #1f6f43; }
          .gaa-run .gaa-status-halted, .gaa-run .gaa-status-failed { background: #8e1519; }
          .gaa-run .gaa-status-awaiting_permission { background: #9e6a03; }
          .gaa-run .gaa-nav { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 10px; }
          .gaa-run button { background: #21262d; color: #e6edf3; border: 1px solid #30363d;
                            border-radius: 6px; padding: 3px 10px; cursor: pointer; }
          .gaa-run button:disabled { opacity: 0.4; cursor: default; }
          .gaa-run .gaa-src { border: 1px solid #30363d; border-radius: 6px; overflow-x: auto;
                              margin-bottom: 10px; }
          .gaa-run .gaa-line { display: flex; white-space: pre; line-height: 1.5; }
          .gaa-run .gaa-line.dim { opacity: 0.35; }
          .gaa-run .gaa-line.current { background: #16261d; }
          .gaa-run .gaa-gutter { width: 52px; flex: none; text-align: right; padding-right: 8px;
                                 color: #484f58; user-select: none; }
          .gaa-run .gaa-bp { color: #f85149; cursor: pointer; }
          .gaa-run .gaa-bp-off { color: #30363d; cursor: pointer; }
          .gaa-run .cmt { color: #8b949e; font-style: italic; }
          .gaa-run .tag { color: #ff7b72; }
          .gaa-run .kw { color: #d2a8ff; }
          .gaa-run .str { color: #a5d6ff; }
          .gaa-run .num { color: #79c0ff; }
          .gaa-run .ident { color: #e6edf3; }
          .gaa-run .punct { color: #8b949e; }
          .gaa-run .gaa-panel { border: 1px solid #30363d; border-radius: 6px; padding: 8px;
                                margin-bottom: 10px; }
          .gaa-run .gaa-perm { border-color: #9e6a03; }
          .gaa-run .gaa-steps { display: flex; flex-direction: column; gap: 4px; }
          .gaa-run .gaa-chip { padding: 1px 6px; border-radius: 8px; background: #21262d; }
          .gaa-run .gaa-chip.completed { background: #1f6f43; }
          .gaa-run .gaa-chip.failed, .gaa-run .gaa-chip.declined { background: #8e1519; }
          .gaa-run .gaa-chip.pending { background: #9e6a03; }
          .gaa-run .gaa-chip.not_reached, .gaa-run .gaa-chip.skipped { background: #30363d; }
          .gaa-run input[type=text] { background: #0d1117; color: #e6edf3;
                                      border: 1px solid #30363d; border-radius: 6px; padding: 3px 6px; }
        </style>

        <div class="gaa-head">
          <strong>Approval run</strong>
          <code>{@model.run_id}</code>
          <.status_badge model={@model} />
          <span :if={@error} class="gaa-badge" style="background:#8e1519">{@error}</span>
        </div>

        <div class="gaa-nav">
          <button phx-click="cmd" phx-value-cmd="step" disabled={not @model.can.step}>Step</button>
          <button phx-click="cmd" phx-value-cmd="next" disabled={not @model.can.next}>Next</button>
          <button phx-click="cmd" phx-value-cmd="run_all" disabled={not @model.can.run_all}>
            Run All
          </button>
          <button
            :if={@model.can.retry}
            phx-click="cmd"
            phx-value-cmd="retry"
          >
            Retry
          </button>
          <button :if={@model.can.skip} phx-click="cmd" phx-value-cmd="skip">Skip</button>
          <form phx-submit="halt" style="display:inline-flex;gap:6px">
            <input type="text" name="reason" placeholder="halt reason (optional)" />
            <button type="submit" disabled={not @model.can.halt}>Halt</button>
          </form>
        </div>

        <div :if={@model.awaiting} class="gaa-panel gaa-perm" id="gaa-permission">
          <div>
            <strong>Permission required</strong> — step {@model.awaiting.step}: {@model.awaiting.title}
          </div>
          <div :for={call <- @model.awaiting.calls}>
            <code>{call.endpoint}:{call.command}</code>
          </div>
          <div :if={@model.awaiting.confirm}>
            Confirm phrase: <strong>{@model.awaiting.confirm}</strong>
          </div>
          <div class="gaa-nav" style="margin-top:6px">
            <button phx-click="cmd" phx-value-cmd="approve">Approve once</button>
            <button
              :if={!@model.awaiting.confirm}
              phx-click="grant"
              phx-value-effect="allow"
              phx-value-scope="session"
            >
              Allow (session)
            </button>
            <button
              :if={!@model.awaiting.confirm}
              phx-click="grant"
              phx-value-effect="allow"
              phx-value-scope="hour"
            >
              Allow (1 hour)
            </button>
            <button
              :if={!@model.awaiting.confirm}
              phx-click="grant"
              phx-value-effect="allow"
              phx-value-scope="always"
            >
              Allow (always)
            </button>
            <button phx-click="grant" phx-value-effect="block" phx-value-scope="session">
              Block (session)
            </button>
            <button phx-click="grant" phx-value-effect="block" phx-value-scope="always">
              Block (always)
            </button>
            <button phx-click="cmd" phx-value-cmd="decline">Decline</button>
          </div>
        </div>

        <div class="gaa-src" id="gaa-source">
          <div
            :for={line <- @model.lines}
            class={["gaa-line", line.dim && "dim", line.current && "current"]}
          >
            <span class="gaa-gutter">
              <span
                :if={line.step_start}
                class={(line.bp && "gaa-bp") || "gaa-bp-off"}
                phx-click="toggle_bp"
                phx-value-step={line.step}
              >
                ●
              </span>
              {line.no}
            </span>
            <span><span :for={{class, text} <- line.spans} class={class}>{text}</span></span>
          </div>
        </div>

        <div class="gaa-panel">
          <strong>Steps</strong>
          <div class="gaa-steps">
            <div :for={step <- @model.steps}>
              <span class={["gaa-chip", to_string(step.status)]}>{step.status}</span>
              <code>{step.id}</code> {step.title}
              <span :if={step.result && step.result.error} class="gaa-chip failed">
                {step.result.error}
              </span>
            </div>
          </div>
        </div>

        <div class="gaa-panel">
          <form phx-submit="annotate" style="display:inline-flex;gap:6px">
            <input type="hidden" name="target" value={@model.pending || "run"} />
            <input type="text" name="text" placeholder={"note for #{@model.pending || "run"}"} />
            <button type="submit">Add note</button>
          </form>
          <div :for={note <- @model.notes}><code>{note.target}</code> {note.text}</div>
        </div>

        <div :if={@model.terminal} class="gaa-panel" id="gaa-result">
          <div :if={@model.halt}>
            <strong>Halted:</strong> {@model.halt.reason} ({@model.halt.actor})
          </div>
          <div :if={@model.result && map_size(@model.result.outputs) > 0}>
            <strong>Outputs</strong>
            <div :for={{key, value} <- @model.result.outputs}>
              <code>{key}</code> = <code>{inspect(value)}</code>
            </div>
          </div>
        </div>
      </div>
      """
    end
  end
end
