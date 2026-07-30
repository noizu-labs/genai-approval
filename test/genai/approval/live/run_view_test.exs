defmodule GenAI.Approval.Live.RunViewTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias GenAI.Approval.Executor.Local
  alias GenAI.Approval.Fixtures
  alias GenAI.Approval.Live.RunView

  @endpoint GenAI.Approval.Test.Endpoint

  # Five steps, a branch, a breakpoint, and hostile content in a title.
  @demo_script """
  {{!-- release helper --}}
  {{#endpoint "local"}}
    transport = "local"
  {{/endpoint}}
  {{#vars}}
    deploy : boolean = true
    report : object?
  {{/vars}}
  {{#step "Check status"}}
    {{assign report = call("local", "status.check", env="prod")}}
  {{/step}}
  {{#if deploy}}
    {{#step "Deploy" breakpoint=true}}
      {{call "local" "deploy.run" env="prod"}}
    {{/step}}
    {{#step "Verify"}}
      {{call "local" "deploy.verify"}}
    {{/step}}
  {{else}}
    {{#step "Skip deploy"}}
      {{call "local" "notify.skip"}}
    {{/step}}
  {{/if}}
  {{#step "Notify <script>alert(1)</script> &copy"}}
    {{call "local" "notify.done" msg="all done"}}
  {{/step}}
  {{#outputs}}
    checked = report.ok
  {{/outputs}}
  """

  defp handlers(test_pid) do
    ok = fn cmd ->
      fn args, ctx ->
        send(test_pid, {:called, ctx.step_id, cmd, args})
        {:ok, %{"ok" => true}}
      end
    end

    %{
      "status.check" => ok.("status.check"),
      "deploy.run" => ok.("deploy.run"),
      "deploy.verify" => ok.("deploy.verify"),
      "notify.skip" => ok.("notify.skip"),
      "notify.done" => ok.("notify.done")
    }
  end

  defp start_run!(opts \\ []) do
    {:ok, script} = GenAI.Approval.load(@demo_script)

    {:ok, run} =
      GenAI.Approval.start_run(
        script,
        Keyword.merge(
          [
            executors: %{"local" => {Local, handlers(self())}},
            subscriber: self(),
            permission: [
              store: Keyword.get(opts, :store, Fixtures.allow_all_store()),
              subject: "tester",
              session_id: "sess"
            ]
          ],
          Keyword.delete(opts, :store)
        )
      )

    %{run_id: run_id} = GenAI.Approval.info(run)
    {run, run_id}
  end

  defp mount!(run_id) do
    {:ok, view, html} =
      live_isolated(build_conn(), RunView, session: %{"run_id" => run_id})

    {view, html}
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

  describe "AC21 — rendering the shared model" do
    test "highlighted source, gutter, steps, and navbar render" do
      {_run, run_id} = start_run!()
      {_view, html} = mount!(run_id)

      # syntax highlighting classes from the shared model
      assert html =~ ~s(<span class="kw">step</span>)
      assert html =~ ~s(<span class="cmt">)
      assert html =~ ~s(<span class="str">)

      # gutter: line numbers + breakpoint dot on the breakpointed step
      assert html =~ "gaa-gutter"
      assert html =~ ~s(phx-value-step="s2")

      # step list with all five steps
      for title <- ["Check status", "Deploy", "Verify", "Skip deploy"] do
        assert html =~ title
      end

      # navbar
      for label <- ["Step", "Next", "Run All", "Halt"] do
        assert html =~ label
      end

      assert html =~ "paused"
    end

    test "AC23 — hostile script content renders escaped" do
      {run, run_id} = start_run!()
      {view, html} = mount!(run_id)

      refute html =~ "<script>alert(1)</script>"
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"

      # hostile note content is escaped too
      :ok = GenAI.Approval.command(run, {:annotate, "run", "<img src=x onerror=alert(2)>"})

      eventually(fn ->
        html = render(view)
        refute html =~ "<img src=x onerror"
        assert html =~ "&lt;img src=x onerror"
      end)
    end
  end

  describe "AC21 — navbar drives a live run" do
    test "permission prompt appears on step; approve executes" do
      {_run, run_id} = start_run!(store: Fixtures.empty_store())
      {view, _html} = mount!(run_id)

      html = view |> element(~s{button[phx-value-cmd="step"]}) |> render_click()
      assert html =~ "Permission required"
      assert html =~ "local:status.check"

      view |> element(~s{button[phx-value-cmd="approve"]}) |> render_click()
      assert_receive {:called, "s1", "status.check", %{"env" => "prod"}}, 2_000

      eventually(fn ->
        assert render(view) =~ ~s(<span class="gaa-chip completed">)
      end)
    end

    test "run_all pauses at the breakpoint; next finishes; branch dimmed" do
      {_run, run_id} = start_run!()
      {view, _html} = mount!(run_id)

      view |> element(~s{button[phx-value-cmd="run_all"]}) |> render_click()
      assert_receive {:called, "s1", "status.check", _}, 2_000

      eventually(fn ->
        html = render(view)
        # paused before the breakpointed Deploy step
        assert html =~ "paused"
        assert html =~ "gaa-line current"
      end)

      refute_received {:called, "s2", _, _}

      view |> element(~s{button[phx-value-cmd="next"]}) |> render_click()
      assert_receive {:called, "s2", "deploy.run", _}, 2_000
      assert_receive {:called, "s3", "deploy.verify", _}, 2_000
      assert_receive {:called, "s5", "notify.done", _}, 2_000

      eventually(fn ->
        html = render(view)
        assert html =~ "completed"
        # untaken else-branch dimmed in source + not_reached chip
        assert html =~ "gaa-line dim"
        assert html =~ "not_reached"
        # outputs panel
        assert html =~ "checked"
      end)

      refute_received {:called, "s4", _, _}
    end

    test "breakpoint gutter toggles" do
      {run, run_id} = start_run!()
      {view, _html} = mount!(run_id)

      # s1 has no breakpoint; toggle it on via the gutter dot
      view |> element(~s{#gaa-source span[phx-value-step="s1"]}) |> render_click()

      snapshot = GenAI.Approval.snapshot(run)
      assert Enum.find(snapshot.steps, &(&1.id == "s1")).breakpoint

      html = render(view)
      assert html =~ "gaa-bp"
    end

    test "halt form sends the reason" do
      {_run, run_id} = start_run!()
      {view, _html} = mount!(run_id)

      html =
        view
        |> element(~s{form[phx-submit="halt"]})
        |> render_submit(%{"reason" => "not in prod hours"})

      assert html =~ "halted"
      assert html =~ "not in prod hours"
      assert html =~ "Halted:"
    end

    test "note form annotates the run" do
      {run, run_id} = start_run!()
      {view, _html} = mount!(run_id)

      html =
        view
        |> element(~s{form[phx-submit="annotate"]})
        |> render_submit(%{"target" => "run", "text" => "checked with ops"})

      assert html =~ "checked with ops"

      snapshot = GenAI.Approval.snapshot(run)

      assert [%{target: "run", text: "checked with ops"}] =
               Enum.map(snapshot.notes, &Map.take(&1, [:target, :text]))
    end
  end
end
