defmodule GenAI.Approval.Render do
  @moduledoc """
  Shared rendering model for approval-script UIs (PRD §7.3).

  Both reference UIs (LiveView, Hologram) consume the same structure so they
  stay in feature parity:

    * `highlight/1` — tolerant token classifier: source → lines of
      `{class, text}` spans. Never raises, even on invalid scripts.
    * `model/1` — a `Runner.snapshot/0` → UI model: highlighted lines
      annotated with step ranges (current / dimmed-untaken / breakpoint
      gutter), step chips, and navbar affordances.

  Classes: `cmt tag kw str num ident punct ws txt`.
  """

  @keywords MapSet.new(~w(endpoint vars step if unless else outputs assign call credential
                 and or not true false null))

  @terminal [:completed, :halted, :failed]

  # -- highlight -------------------------------------------------------------

  @spec highlight(String.t()) :: [%{no: pos_integer(), spans: [{String.t(), String.t()}]}]
  def highlight(source) when is_binary(source) do
    source
    |> scan_base([])
    |> Enum.reverse()
    |> to_lines()
  end

  defp scan_base("", acc), do: acc

  defp scan_base("{{!--" <> rest, acc), do: scan_comment(rest, :long, [{"cmt", "{{!--"} | acc])
  defp scan_base("{{!" <> rest, acc), do: scan_comment(rest, :short, [{"cmt", "{{!"} | acc])
  defp scan_base("{{" <> rest, acc), do: scan_must(rest, [{"tag", "{{"} | acc])
  defp scan_base("\n" <> rest, acc), do: scan_base(rest, [:nl | acc])

  defp scan_base(bin, acc) do
    {piece, rest} = lexeme(bin)
    scan_base(rest, [piece | acc])
  end

  defp scan_comment("--}}" <> rest, :long, acc), do: scan_base(rest, [{"cmt", "--}}"} | acc])
  defp scan_comment("}}" <> rest, :short, acc), do: scan_base(rest, [{"cmt", "}}"} | acc])
  defp scan_comment("\n" <> rest, m, acc), do: scan_comment(rest, m, [:nl | acc])

  defp scan_comment(<<c::utf8, rest::binary>>, m, acc),
    do: scan_comment(rest, m, [{"cmt", <<c::utf8>>} | acc])

  defp scan_comment("", _m, acc), do: acc

  defp scan_must("", acc), do: acc
  defp scan_must("}}" <> rest, acc), do: scan_base(rest, [{"tag", "}}"} | acc])
  defp scan_must("\n" <> rest, acc), do: scan_must(rest, [:nl | acc])

  defp scan_must(<<c, rest::binary>>, acc) when c in [?#, ?/],
    do: scan_must(rest, [{"tag", <<c>>} | acc])

  defp scan_must(bin, acc) do
    {piece, rest} = lexeme(bin)
    scan_must(rest, [piece | acc])
  end

  defp lexeme(<<c, _::binary>> = bin) when c in [?\s, ?\t, ?\r] do
    {run, rest} = take_while(bin, &(&1 in [?\s, ?\t, ?\r]))
    {{"ws", run}, rest}
  end

  defp lexeme(<<?", rest::binary>>) do
    {content, rest2} = take_string(rest, ["\""])
    {{"str", content}, rest2}
  end

  defp lexeme(<<c, _::binary>> = bin) when c in ?0..?9 do
    {run, rest} = take_while(bin, &(&1 in ?0..?9 or &1 == ?.))
    {{"num", run}, rest}
  end

  defp lexeme(<<c, _::binary>> = bin) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    {word, rest} = take_while(bin, &(&1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9 or &1 == ?_))
    class = if MapSet.member?(@keywords, word), do: "kw", else: "ident"
    {{class, word}, rest}
  end

  defp lexeme(<<c::utf8, rest::binary>>), do: {{"punct", <<c::utf8>>}, rest}

  defp take_string(<<?\\, esc, rest::binary>>, acc),
    do: take_string(rest, [<<?\\, esc>> | acc])

  defp take_string(<<?", rest::binary>>, acc),
    do: {[?" | acc] |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_string(<<?\n, _::binary>> = rest, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_string(<<c::utf8, rest::binary>>, acc), do: take_string(rest, [<<c::utf8>> | acc])
  defp take_string("", acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp take_while(bin, fun), do: do_take_while(bin, fun, [])

  defp do_take_while(<<c, rest::binary>> = bin, fun, acc) do
    if fun.(c) do
      do_take_while(rest, fun, [c | acc])
    else
      {acc |> Enum.reverse() |> List.to_string(), bin}
    end
  end

  defp do_take_while("", _fun, acc), do: {acc |> Enum.reverse() |> List.to_string(), ""}

  defp to_lines(pieces) do
    {lines, spans, no} =
      Enum.reduce(pieces, {[], [], 1}, fn
        :nl, {lines, spans, no} ->
          {[%{no: no, spans: merge_spans(Enum.reverse(spans))} | lines], [], no + 1}

        piece, {lines, spans, no} ->
          {lines, [piece | spans], no}
      end)

    Enum.reverse([%{no: no, spans: merge_spans(Enum.reverse(spans))} | lines])
  end

  defp merge_spans(spans) do
    Enum.reduce(spans, [], fn
      {class, text}, [{class, prev} | rest] -> [{class, prev <> text} | rest]
      piece, acc -> [piece | acc]
    end)
    |> Enum.reverse()
  end

  # -- UI model ---------------------------------------------------------------

  @doc "Build the full UI model from a `GenAI.Approval.snapshot/1`."
  @spec model(map()) :: map()
  def model(snapshot) do
    lines =
      snapshot.source
      |> highlight()
      |> Enum.map(&annotate_line(&1, snapshot))

    pending_step = Enum.find(snapshot.steps, &(&1.id == snapshot.pending))
    paused_ready = snapshot.status == :paused and not snapshot.pending_failed

    can = %{
      step: paused_ready,
      next: paused_ready,
      run_all: paused_ready,
      halt: snapshot.status not in @terminal,
      retry: snapshot.status == :paused and snapshot.pending_failed,
      skip:
        snapshot.status == :paused and snapshot.pending_failed and
          (pending_step && pending_step.attrs["optional"] == true) == true,
      approve: snapshot.status == :awaiting_permission
    }

    Map.merge(snapshot, %{
      lines: lines,
      can: can,
      terminal: snapshot.status in @terminal
    })
  end

  defp annotate_line(line, snapshot) do
    step =
      Enum.find(snapshot.steps, fn s ->
        line.no >= s.line and line.no <= (s.end_line || s.line)
      end)

    Map.merge(line, %{
      step: step && step.id,
      step_start: (step && line.no == step.line) == true,
      dim: (step && step.status == :not_reached) == true,
      current: (step && step.status == :pending) == true,
      bp: (step && step.breakpoint && line.no == step.line) == true
    })
  end
end
