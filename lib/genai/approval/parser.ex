defmodule GenAI.Approval.Parser do
  @moduledoc """
  Recursive-descent parser for the approval-script grammar (PRD §5).

  `parse/2` returns `{:ok, %Script{}}` or `{:error, [%Error{}]}` — parse
  errors are a single-element list; static checks may report several.
  Nothing partially parsed is ever returned (R5.8).
  """

  alias GenAI.Approval.{Error, Lexer, Script}
  alias GenAI.Approval.Script.{Assign, Call, Endpoint, If, Output, Step, VarDecl}

  @default_max_size 64 * 1024
  @default_max_steps 50

  @types ~w(string number boolean object list)

  @spec parse(String.t(), keyword()) :: {:ok, Script.t()} | {:error, [Error.t()]}
  def parse(source, opts \\ []) when is_binary(source) do
    max_size = Keyword.get(opts, :max_script_size, @default_max_size)
    max_steps = Keyword.get(opts, :max_steps, @default_max_steps)

    cond do
      byte_size(source) > max_size ->
        {:error,
         [
           Error.new(
             :script_too_large,
             "script is #{byte_size(source)} bytes (max #{max_size})",
             {1, 1}
           )
         ]}

      true ->
        case Lexer.segments(source) do
          {:error, err} ->
            {:error, [err]}

          {:ok, segs} ->
            try do
              do_parse(segs, source, max_steps)
            catch
              {:parse_error, %Error{} = err} -> {:error, [err]}
            end
        end
    end
  end

  defp do_parse(segs, source, max_steps) do
    {endpoints, segs} = parse_endpoints(skip_ws(segs), %{})
    {vars, segs} = parse_vars(skip_ws(segs))
    {body, segs, counter} = parse_body(skip_ws(segs), nil, [], 0)
    {outputs, segs} = parse_outputs(skip_ws(segs))
    ensure_eof(skip_ws(segs))

    if counter > max_steps do
      fail(:too_many_steps, "script declares #{counter} steps (max #{max_steps})", {1, 1})
    end

    script = %Script{
      endpoints: endpoints,
      vars: vars,
      body: body,
      outputs: outputs,
      steps: Script.collect_steps(body),
      source: source
    }

    case GenAI.Approval.StaticChecks.check(script) do
      [] -> {:ok, script}
      errors -> {:error, errors}
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp fail(code, message, pos), do: throw({:parse_error, Error.new(code, message, pos)})

  defp skip_ws([{:text, t, pos} | rest] = segs) do
    if String.trim(t) == "" do
      skip_ws(rest)
    else
      # Raw text is only legal inside endpoint/vars/outputs blocks; those
      # consume their text segments before we get here.
      {l, c} = pos
      offset = leading_ws_lines(t)
      fail(:unexpected_text, "unexpected text outside a declaration block", {l + offset, c})
      segs
    end
  end

  defp skip_ws(segs), do: segs

  defp leading_ws_lines(t) do
    t
    |> String.split("\n")
    |> Enum.take_while(&(String.trim(&1) == ""))
    |> length()
  end

  defp block_open([{:punct, "#", _}, {:ident, tag, _} | rest]), do: {tag, rest}
  defp block_open(_), do: nil

  defp block_close([{:punct, "/", _}, {:ident, tag, _}]), do: tag
  defp block_close(_), do: nil

  # -- preamble --------------------------------------------------------------

  defp parse_endpoints([{:mustache, toks, pos} = seg | rest] = segs, acc) do
    case block_open(toks) do
      {"endpoint", [{:string, name, _}]} ->
        if Map.has_key?(acc, name) do
          fail(:duplicate_endpoint, "endpoint #{inspect(name)} declared twice", pos)
        end

        {ep, rest2} = parse_endpoint_body(name, pos, rest)
        parse_endpoints(skip_ws(rest2), Map.put(acc, name, ep))

      {"endpoint", _} ->
        fail(:invalid_endpoint, "expected {{#endpoint \"name\"}}", pos)

      _ ->
        _ = seg
        {acc, segs}
    end
  end

  defp parse_endpoints(segs, acc), do: {acc, segs}

  defp parse_endpoint_body(name, pos, segs) do
    {kvs, rest} = collect_decl_text(segs, "endpoint", pos, [])

    ep =
      Enum.reduce(kvs, %Endpoint{name: name, line: elem(pos, 0)}, fn {key, value, kv_pos}, ep ->
        case {key, value} do
          {"transport", {:string, s}} ->
            %{ep | transport: s}

          {"url", {:string, s}} ->
            %{ep | url: s}

          {"auth", {:credential, id}} ->
            %{ep | auth: {:credential, id}}

          {"auth", _} ->
            fail(:auth_literal, "auth must be credential(\"id\") — never an inline value", kv_pos)

          {other, {:string, s}} ->
            %{ep | opts: Map.put(ep.opts, other, s)}

          {other, {:credential, id}} ->
            %{ep | opts: Map.put(ep.opts, other, {:credential, id})}
        end
      end)

    if ep.transport == nil do
      fail(:invalid_endpoint, "endpoint #{inspect(name)} missing transport", pos)
    end

    {ep, rest}
  end

  # Collect the raw-text declarations inside endpoint/vars/outputs until the
  # matching close tag; returns parsed `key = value` / declaration token runs.
  defp collect_decl_text(segs, close_tag, open_pos, acc) do
    case segs do
      [{:text, text, pos} | rest] ->
        case Lexer.tokenize(text, pos) do
          {:ok, toks} -> collect_decl_text(rest, close_tag, open_pos, acc ++ [toks])
          {:error, err} -> throw({:parse_error, err})
        end

      [{:mustache, toks, pos} | rest] ->
        if block_close(toks) == close_tag do
          {parse_kv_runs(acc, close_tag), rest}
        else
          fail(:unexpected_token, "unexpected {{...}} inside #{close_tag} block", pos)
        end

      [] ->
        fail(:unterminated, "missing {{/#{close_tag}}}", open_pos)
    end
  end

  # kv grammar: ident "=" (string | credential("id"))
  defp parse_kv_runs(token_runs, _close_tag) do
    toks = List.flatten(token_runs)
    parse_kvs(toks, [])
  end

  defp parse_kvs([], acc), do: Enum.reverse(acc)

  defp parse_kvs([{:ident, key, pos}, {:punct, "=", _} | rest], acc) do
    case rest do
      [{:string, s, _} | rest2] ->
        parse_kvs(rest2, [{key, {:string, s}, pos} | acc])

      [{:ident, "credential", _}, {:punct, "(", _}, {:string, id, _}, {:punct, ")", _} | rest2] ->
        parse_kvs(rest2, [{key, {:credential, id}, pos} | acc])

      _ ->
        fail(:unexpected_token, "expected string or credential(\"id\") after #{key} =", pos)
    end
  end

  defp parse_kvs([{_, _, pos} | _], _acc) do
    fail(:unexpected_token, "expected `key = value` declaration", pos)
  end

  # -- vars ------------------------------------------------------------------

  defp parse_vars([{:mustache, toks, pos} | rest] = segs) do
    case block_open(toks) do
      {"vars", []} ->
        {decls, rest2} = collect_var_text(rest, pos, [])
        {decls, rest2}

      _ ->
        _ = pos
        {[], segs}
    end
  end

  defp parse_vars(segs), do: {[], segs}

  defp collect_var_text(segs, open_pos, acc) do
    case segs do
      [{:text, text, pos} | rest] ->
        case Lexer.tokenize(text, pos) do
          {:ok, toks} -> collect_var_text(rest, open_pos, acc ++ toks)
          {:error, err} -> throw({:parse_error, err})
        end

      [{:mustache, toks, pos} | rest] ->
        if block_close(toks) == "vars" do
          {parse_var_decls(acc, []), rest}
        else
          fail(:unexpected_token, "unexpected {{...}} inside vars block", pos)
        end

      [] ->
        fail(:unterminated, "missing {{/vars}}", open_pos)
    end
  end

  # decl: ident ":" type ["?"] ["=" literal]
  defp parse_var_decls([], acc), do: Enum.reverse(acc)

  defp parse_var_decls([{:ident, name, pos}, {:punct, ":", _}, {:ident, type, tpos} | rest], acc) do
    unless type in @types do
      fail(
        :unknown_type,
        "unknown type #{inspect(type)} (expected one of #{Enum.join(@types, ", ")})",
        tpos
      )
    end

    {nullable, rest} =
      case rest do
        [{:punct, "?", _} | r] -> {true, r}
        _ -> {false, rest}
      end

    {default, has_default, rest} =
      case rest do
        [{:punct, "=", _} | r] ->
          {value, r2} = parse_literal(r, pos)
          {value, true, r2}

        _ ->
          {nil, false, rest}
      end

    decl = %VarDecl{
      name: name,
      type: type,
      nullable: nullable,
      default: default,
      has_default: has_default,
      line: elem(pos, 0)
    }

    parse_var_decls(rest, [decl | acc])
  end

  defp parse_var_decls([{_, _, pos} | _], _acc) do
    fail(:unexpected_token, "expected `name : type [?] [= literal]` declaration", pos)
  end

  defp parse_literal(toks, pos) do
    case toks do
      [{:string, s, _} | rest] -> {s, rest}
      [{:number, n, _} | rest] -> {n, rest}
      [{:ident, "true", _} | rest] -> {true, rest}
      [{:ident, "false", _} | rest] -> {false, rest}
      [{:ident, "null", _} | rest] -> {nil, rest}
      [{:punct, "[", _} | rest] -> parse_literal_list(rest, [], pos)
      [{_, _, p} | _] -> fail(:unexpected_token, "expected a literal", p)
      [] -> fail(:unexpected_token, "expected a literal", pos)
    end
  end

  defp parse_literal_list([{:punct, "]", _} | rest], acc, _pos), do: {Enum.reverse(acc), rest}

  defp parse_literal_list(toks, acc, pos) do
    {value, rest} = parse_literal(toks, pos)

    case rest do
      [{:punct, ",", _} | r] -> parse_literal_list(r, [value | acc], pos)
      [{:punct, "]", _} | r] -> {Enum.reverse([value | acc]), r}
      [{_, _, p} | _] -> fail(:unexpected_token, "expected , or ] in list literal", p)
      [] -> fail(:unterminated, "unterminated list literal", pos)
    end
  end

  # -- body ------------------------------------------------------------------

  # Returns {nodes, rest_segments, step_counter}. `close` is nil at top level,
  # "if"/"unless" inside a conditional. Top level stops at {{#outputs}} / EOF.
  defp parse_body(segs, close, acc, counter) do
    segs = skip_ws_soft(segs, close)

    case segs do
      [] when close == nil ->
        {Enum.reverse(acc), [], counter}

      [] ->
        fail(:unterminated, "missing {{/#{close}}}", {1, 1})

      [{:mustache, toks, pos} | rest] ->
        cond do
          block_close(toks) == close and close != nil ->
            {Enum.reverse(acc), [{:closed, pos} | rest], counter}

          match?([{:ident, "else", _}], toks) and close in ["if", "unless"] ->
            {Enum.reverse(acc), [{:else, pos} | rest], counter}

          true ->
            case block_open(toks) do
              {"step", args} ->
                {step, rest2, counter2} = parse_step(args, pos, rest, counter)
                parse_body(rest2, close, [step | acc], counter2)

              {"if", cond_toks} ->
                {node, rest2, counter2} = parse_if(cond_toks, pos, rest, counter, false)
                parse_body(rest2, close, [node | acc], counter2)

              {"unless", cond_toks} ->
                {node, rest2, counter2} = parse_if(cond_toks, pos, rest, counter, true)
                parse_body(rest2, close, [node | acc], counter2)

              {"outputs", _} when close == nil ->
                {Enum.reverse(acc), segs, counter}

              {tag, _} when tag in ["endpoint", "vars"] ->
                fail(:section_order, "#{tag} block must appear before the script body", pos)

              {tag, _} ->
                fail(
                  :unknown_block,
                  "unknown block {{##{tag}}} — no such construct in approval scripts",
                  pos
                )

              nil ->
                case toks do
                  [{:ident, kw, _} | _] when kw in ["assign", "call"] ->
                    fail(
                      :stmt_outside_step,
                      "{{#{kw} ...}} must appear inside a {{#step}} block",
                      pos
                    )

                  _ ->
                    fail(:unexpected_token, "unexpected {{...}} in script body", pos)
                end
            end
        end
    end
  end

  # like skip_ws but tolerates trailing close markers handled by parse_body
  defp skip_ws_soft([{:text, t, pos} | rest] = segs, close) do
    if String.trim(t) == "" do
      skip_ws_soft(rest, close)
    else
      {l, c} = pos
      offset = leading_ws_lines(t)
      fail(:unexpected_text, "unexpected text in script body", {l + offset, c})
      segs
    end
  end

  defp skip_ws_soft(segs, _close), do: segs

  # -- step ------------------------------------------------------------------

  defp parse_step(args, pos, segs, counter) do
    {title, attr_toks} =
      case args do
        [{:string, t, _} | rest] -> {t, rest}
        _ -> fail(:unexpected_token, "expected {{#step \"title\" ...}}", pos)
      end

    attrs = parse_step_attrs(attr_toks, %{})
    counter = counter + 1
    id = "s#{counter}"

    {stmts, rest, end_line} = parse_step_statements(segs, pos, [])

    step = %Step{
      id: id,
      title: title,
      attrs: attrs,
      statements: stmts,
      calls: extract_calls(stmts),
      line: elem(pos, 0),
      end_line: end_line
    }

    {step, rest, counter}
  end

  defp parse_step_attrs([], acc), do: acc

  defp parse_step_attrs([{:ident, key, pos}, {:punct, "=", _} | rest], acc)
       when key in ["breakpoint", "note", "confirm", "optional"] do
    {value, rest2} = parse_literal(rest, pos)
    parse_step_attrs(rest2, Map.put(acc, key, value))
  end

  defp parse_step_attrs([{_, _, pos} | _], _acc) do
    fail(
      :unexpected_token,
      "expected step attribute (breakpoint / note / confirm / optional)",
      pos
    )
  end

  defp parse_step_statements(segs, open_pos, acc) do
    case segs do
      [{:text, t, pos} | rest] ->
        if String.trim(t) == "" do
          parse_step_statements(rest, open_pos, acc)
        else
          fail(:unexpected_text, "unexpected text inside step block", pos)
        end

      [{:mustache, toks, pos} | rest] ->
        cond do
          block_close(toks) == "step" ->
            {Enum.reverse(acc), rest, elem(pos, 0)}

          match?([{:ident, "assign", _} | _], toks) ->
            [_ | t] = toks
            stmt = parse_assign(t, pos)
            parse_step_statements(rest, open_pos, [stmt | acc])

          match?([{:ident, "call", _} | _], toks) ->
            [_ | t] = toks
            stmt = parse_call_stmt(t, pos)
            parse_step_statements(rest, open_pos, [stmt | acc])

          block_open(toks) != nil ->
            {tag, _} = block_open(toks)
            fail(:unexpected_token, "blocks ({{##{tag}}}) cannot be nested inside a step", pos)

          true ->
            fail(:unexpected_token, "expected {{assign ...}} or {{call ...}} inside step", pos)
        end

      [] ->
        fail(:unterminated, "missing {{/step}}", open_pos)
    end
  end

  defp parse_assign(toks, pos) do
    case toks do
      [{:ident, var, _}, {:punct, "=", _} | rest] ->
        {expr, rest2} = parse_expr(rest, pos)
        ensure_consumed(rest2)
        %Assign{var: var, expr: expr, line: elem(pos, 0)}

      _ ->
        fail(:unexpected_token, "expected {{assign var = expr}}", pos)
    end
  end

  defp parse_call_stmt(toks, pos) do
    case toks do
      [{:string, endpoint, _}, {:string, command, _} | rest] ->
        args = parse_args(rest, pos, [])
        %Call{endpoint: endpoint, command: command, args: args, line: elem(pos, 0)}

      _ ->
        fail(:unexpected_token, "expected {{call \"endpoint\" \"command\" arg=expr ...}}", pos)
    end
  end

  # arg list: ident "=" expr, optional commas between args
  defp parse_args([], _pos, acc), do: Enum.reverse(acc)

  defp parse_args([{:punct, ",", _} | rest], pos, acc), do: parse_args(rest, pos, acc)

  defp parse_args([{:ident, name, _}, {:punct, "=", _} | rest], pos, acc) do
    {expr, rest2} = parse_expr_arg(rest, pos)
    parse_args(rest2, pos, [{name, expr} | acc])
  end

  defp parse_args([{_, _, p} | _], _pos, _acc) do
    fail(:unexpected_token, "expected `name = expr` argument", p)
  end

  defp ensure_consumed([]), do: :ok

  defp ensure_consumed([{_, _, pos} | _]) do
    fail(:unexpected_token, "unexpected trailing tokens", pos)
  end

  defp extract_calls(stmts) do
    Enum.flat_map(stmts, fn
      %Call{endpoint: e, command: c} -> [{e, c}]
      %Assign{expr: expr} -> calls_in_expr(expr)
    end)
  end

  @doc false
  def calls_in_expr({:call, e, c, args}) do
    [{e, c}] ++ Enum.flat_map(args, fn {_n, a} -> calls_in_expr(a) end)
  end

  def calls_in_expr({:not, e}), do: calls_in_expr(e)
  def calls_in_expr({:op, _op, l, r}), do: calls_in_expr(l) ++ calls_in_expr(r)
  def calls_in_expr({:lit_list, es}), do: Enum.flat_map(es, &calls_in_expr/1)
  def calls_in_expr(_), do: []

  # -- if / unless -----------------------------------------------------------

  defp parse_if(cond_toks, pos, segs, counter, negate) do
    {condition, rest_toks} = parse_expr(cond_toks, pos)
    ensure_consumed(rest_toks)

    tag = if negate, do: "unless", else: "if"
    {then_body, segs2, counter2} = parse_body(segs, tag, [], counter)

    case segs2 do
      [{:else, else_pos} | rest] ->
        if negate do
          fail(:unexpected_token, "{{else}} is not supported in {{#unless}}", pos)
        end

        {else_body, segs3, counter3} = parse_body(rest, tag, [], counter2)

        case segs3 do
          [{:closed, close_pos} | rest2] ->
            node = %If{
              condition: condition,
              then_body: then_body,
              else_body: else_body,
              negate: negate,
              line: elem(pos, 0),
              else_line: elem(else_pos, 0),
              end_line: elem(close_pos, 0)
            }

            {node, rest2, counter3}

          _ ->
            fail(:unterminated, "missing {{/#{tag}}}", pos)
        end

      [{:closed, close_pos} | rest] ->
        node = %If{
          condition: condition,
          then_body: then_body,
          else_body: [],
          negate: negate,
          line: elem(pos, 0),
          end_line: elem(close_pos, 0)
        }

        {node, rest, counter2}

      _ ->
        fail(:unterminated, "missing {{/#{tag}}}", pos)
    end
  end

  # -- outputs ---------------------------------------------------------------

  defp parse_outputs([{:mustache, toks, pos} | rest] = segs) do
    case block_open(toks) do
      {"outputs", []} ->
        {entries, rest2} = collect_output_text(rest, pos, [])
        {entries, rest2}

      _ ->
        _ = pos
        {[], segs}
    end
  end

  defp parse_outputs(segs), do: {[], segs}

  defp collect_output_text(segs, open_pos, acc) do
    case segs do
      [{:text, text, pos} | rest] ->
        case Lexer.tokenize(text, pos) do
          {:ok, toks} -> collect_output_text(rest, open_pos, acc ++ toks)
          {:error, err} -> throw({:parse_error, err})
        end

      [{:mustache, toks, pos} | rest] ->
        if block_close(toks) == "outputs" do
          {parse_output_entries(acc, []), rest}
        else
          fail(:unexpected_token, "unexpected {{...}} inside outputs block", pos)
        end

      [] ->
        fail(:unterminated, "missing {{/outputs}}", open_pos)
    end
  end

  defp parse_output_entries([], acc), do: Enum.reverse(acc)

  defp parse_output_entries([{:ident, name, pos}, {:punct, "=", _} | rest], acc) do
    {expr, rest2} = parse_output_expr(rest, pos)
    entry = %Output{name: name, expr: expr, line: elem(pos, 0)}
    parse_output_entries(rest2, [entry | acc])
  end

  defp parse_output_entries([{_, _, pos} | _], _acc) do
    fail(:unexpected_token, "expected `name = expr` output declaration", pos)
  end

  # An output expr ends where the next `ident =` declaration begins.
  defp parse_output_expr(toks, pos) do
    {expr, rest} = parse_expr(toks, pos)

    case rest do
      [] -> {expr, rest}
      [{:ident, _, _}, {:punct, "=", _} | _] -> {expr, rest}
      [{_, _, p} | _] -> fail(:unexpected_token, "unexpected token in outputs block", p)
    end
  end

  # An arg expr ends at `,`, at the next `ident =`, or at `)` / end.
  defp parse_expr_arg(toks, pos), do: parse_expr(toks, pos)

  defp ensure_eof([]), do: :ok

  defp ensure_eof([{:mustache, _, pos} | _]) do
    fail(:unexpected_token, "unexpected content after {{/outputs}}", pos)
  end

  defp ensure_eof([{:text, _, pos} | _]) do
    fail(:unexpected_text, "unexpected text after {{/outputs}}", pos)
  end

  # -- expressions -----------------------------------------------------------
  # precedence: or < and < comparison < unary(not) < primary

  @doc false
  def parse_expr(toks, pos) do
    parse_or(toks, pos)
  end

  defp parse_or(toks, pos) do
    {left, rest} = parse_and(toks, pos)
    parse_or_tail(left, rest, pos)
  end

  defp parse_or_tail(left, [{:ident, "or", _} | rest], pos) do
    {right, rest2} = parse_and(rest, pos)
    parse_or_tail({:op, :or, left, right}, rest2, pos)
  end

  defp parse_or_tail(left, rest, _pos), do: {left, rest}

  defp parse_and(toks, pos) do
    {left, rest} = parse_cmp(toks, pos)
    parse_and_tail(left, rest, pos)
  end

  defp parse_and_tail(left, [{:ident, "and", _} | rest], pos) do
    {right, rest2} = parse_cmp(rest, pos)
    parse_and_tail({:op, :and, left, right}, rest2, pos)
  end

  defp parse_and_tail(left, rest, _pos), do: {left, rest}

  @cmp_ops %{"==" => :==, "!=" => :!=, "<" => :<, ">" => :>, "<=" => :<=, ">=" => :>=}

  defp parse_cmp(toks, pos) do
    {left, rest} = parse_unary(toks, pos)

    case rest do
      [{:punct, op, _} | rest2] when is_map_key(@cmp_ops, op) ->
        {right, rest3} = parse_unary(rest2, pos)
        {{:op, Map.fetch!(@cmp_ops, op), left, right}, rest3}

      _ ->
        {left, rest}
    end
  end

  defp parse_unary([{:ident, "not", _} | rest], pos) do
    {expr, rest2} = parse_unary(rest, pos)
    {{:not, expr}, rest2}
  end

  defp parse_unary(toks, pos), do: parse_primary(toks, pos)

  defp parse_primary(toks, pos) do
    case toks do
      [{:string, s, _} | rest] ->
        {{:lit, s}, rest}

      [{:number, n, _} | rest] ->
        {{:lit, n}, rest}

      [{:ident, "true", _} | rest] ->
        {{:lit, true}, rest}

      [{:ident, "false", _} | rest] ->
        {{:lit, false}, rest}

      [{:ident, "null", _} | rest] ->
        {{:lit, nil}, rest}

      [{:punct, "[", p} | rest] ->
        parse_expr_list(rest, [], p)

      [{:ident, "call", _}, {:punct, "(", p} | rest] ->
        parse_call_expr(rest, p)

      [{:punct, "(", p} | rest] ->
        {expr, rest2} = parse_expr(rest, p)

        case rest2 do
          [{:punct, ")", _} | rest3] -> {expr, rest3}
          _ -> fail(:unexpected_token, "missing closing )", p)
        end

      [{:ident, name, _} | rest] ->
        {path, rest2} = parse_path(rest, [name])
        {{:var, path}, rest2}

      [{_, _, p} | _] ->
        fail(:unexpected_token, "expected an expression", p)

      [] ->
        fail(:unexpected_token, "expected an expression", pos)
    end
  end

  defp parse_path([{:punct, ".", _}, {:ident, seg, _} | rest], acc) do
    parse_path(rest, [seg | acc])
  end

  defp parse_path(rest, acc), do: {Enum.reverse(acc), rest}

  defp parse_expr_list([{:punct, "]", _} | rest], acc, _pos),
    do: {{:lit_list, Enum.reverse(acc)}, rest}

  defp parse_expr_list(toks, acc, pos) do
    {expr, rest} = parse_expr(toks, pos)

    case rest do
      [{:punct, ",", _} | r] -> parse_expr_list(r, [expr | acc], pos)
      [{:punct, "]", _} | r] -> {{:lit_list, Enum.reverse([expr | acc])}, r}
      [{_, _, p} | _] -> fail(:unexpected_token, "expected , or ] in list", p)
      [] -> fail(:unterminated, "unterminated list", pos)
    end
  end

  # call("endpoint", "command", name=expr, ...)
  defp parse_call_expr(toks, pos) do
    case toks do
      [{:string, endpoint, _}, {:punct, ",", _}, {:string, command, _} | rest] ->
        {args, rest2} = parse_call_expr_args(rest, pos, [])
        {{:call, endpoint, command, args}, rest2}

      _ ->
        fail(:unexpected_token, "expected call(\"endpoint\", \"command\", ...)", pos)
    end
  end

  defp parse_call_expr_args([{:punct, ")", _} | rest], _pos, acc), do: {Enum.reverse(acc), rest}

  defp parse_call_expr_args([{:punct, ",", _} | rest], pos, acc),
    do: parse_call_expr_args(rest, pos, acc)

  defp parse_call_expr_args([{:ident, name, _}, {:punct, "=", _} | rest], pos, acc) do
    {expr, rest2} = parse_expr(rest, pos)
    parse_call_expr_args(rest2, pos, [{name, expr} | acc])
  end

  defp parse_call_expr_args([{_, _, p} | _], _pos, _acc) do
    fail(:unexpected_token, "expected `name = expr` or ) in call(...)", p)
  end

  defp parse_call_expr_args([], pos, _acc) do
    fail(:unterminated, "unterminated call(...)", pos)
  end
end
